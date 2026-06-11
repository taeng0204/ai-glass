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
    let file = dir.appendingPathComponent("rollout.jsonl")
    let content = Data((stamped(codexLine) + "\n").utf8)
    try content.write(to: file)

    let store = UsageStore()
    let collector = CodexCollector(root: dir)
    collector.collect(into: store)
    #expect(store.events.count == 1)
    #expect(store.limits[.codex]?.count == 2)
    #expect(store.limits[.codex]?.first { $0.kind == .session5h }?.usedPercent == 34.5)

    // rotation 시뮬레이션: truncate를 collect가 관측 → 오프셋 0 리셋 → 동일 내용 재작성 → 재파싱
    try Data().write(to: file)
    collector.collect(into: store)
    try content.write(to: file)
    collector.collect(into: store)
    #expect(store.events.count == 1) // dedup 키로 중복 적재 차단
}

/// 항목1 회귀 방지: session_meta 첫 줄이 4KB를 초과(긴 payload.instructions)해도
/// 프로젝트명이 정상 부여돼야 한다. 수정 전(4KB 버퍼)에는 첫 줄 파싱 실패 → project nil.
@MainActor @Test func codexCollectorParsesProjectWithLargeSessionMeta() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // ~8KB instructions 문자열 (AGENTS.md 모사) — JSON escape 안전한 문자만 사용
    let bigInstructions = String(repeating: "ABCDEFGHIJ", count: 800) // 8000자
    let sessionMeta = """
    {"type":"session_meta","payload":{"cwd":"/Users/me/hack-nas","instructions":"\(bigInstructions)"}}
    """
    #expect(sessionMeta.utf8.count > 4096) // 첫 줄이 4KB 초과임을 보장

    let file = dir.appendingPathComponent("rollout.jsonl")
    let content = sessionMeta + "\n" + stamped(codexLine) + "\n"
    try Data(content.utf8).write(to: file)

    let store = UsageStore()
    let collector = CodexCollector(root: dir)
    collector.collect(into: store)
    #expect(store.events.count == 1)
    #expect(store.events.first?.project == "hack-nas") // 수정 전: nil
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
    // historyFile은 존재하지 않는 경로로 지정해 실제 홈의 antigravity 히스토리 누출 방지
    let collector = GeminiCollector(root: dir, dailyQuota: 100,
                                    historyFile: dir.appendingPathComponent("nonexistent.jsonl"),
                                    logDir: dir.appendingPathComponent("missing-log"))
    collector.collect(into: store)
    #expect(store.geminiRequestDates.count == 1)
    #expect(store.limits[.gemini]?.first?.usedPercent == 1.0)
}

/// 항목2: GeminiCollector가 legacy logs.json + Antigravity history.jsonl 양쪽에서 요청을 합산.
@MainActor @Test func geminiCollectorMergesLegacyAndAntigravity() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()

    // legacy logs.json: 오늘 1건
    let hashDir = dir.appendingPathComponent("abc123")
    try FileManager.default.createDirectory(at: hashDir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    let legacy = """
    [{"type":"user","timestamp":"\(iso.string(from: now))","message":"hi","messageId":0,"sessionId":"s"}]
    """
    try Data(legacy.utf8).write(to: hashDir.appendingPathComponent("logs.json"))

    // antigravity history.jsonl: 오늘 2건
    let ms = Int(now.timeIntervalSince1970 * 1000)
    let history = """
    {"display":"a","timestamp":\(ms),"workspace":"/Users/me/Desktop/dev/hack-nas"}
    {"display":"b","timestamp":\(ms - 1000),"workspace":"/Users/me/Desktop/dev/ai-glass"}
    """
    let historyFile = dir.appendingPathComponent("history.jsonl")
    try Data(history.utf8).write(to: historyFile)

    let store = UsageStore()
    let collector = GeminiCollector(root: dir, dailyQuota: 100, historyFile: historyFile,
                                    logDir: dir.appendingPathComponent("missing-log"))
    collector.collect(into: store, now: now)
    #expect(store.geminiRequestDates.count == 3) // 1 legacy + 2 antigravity
    #expect(store.limits[.gemini]?.first?.usedPercent == 3.0) // 3/100 = 3%
}

/// 항목3: Antigravity CLI 로그가 있으면 history 프롬프트 수보다 실제 모델 호출 수를 우선한다.
@MainActor @Test func geminiCollectorPrefersAntigravityModelRequestLogs() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 11,
                                                              hour: 12, minute: 0, second: 10)))
    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    let year = try #require(comps.year)
    let month = try #require(comps.month)
    let day = try #require(comps.day)
    let hour = try #require(comps.hour)
    let minute = try #require(comps.minute)
    let second = try #require(comps.second)

    let historyFile = dir.appendingPathComponent("history.jsonl")
    let ms = Int(now.timeIntervalSince1970 * 1000)
    try Data(#"{"display":"prompt","timestamp":\#(ms),"workspace":"/Users/me/proj"}"#.utf8)
        .write(to: historyFile)

    let logDir = dir.appendingPathComponent("log")
    try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let log = (0..<3).map { offset in
        let sec = second - offset
        return String(format: "I%02d%02d %02d:%02d:%02d.000000 1 http_helpers.go:183] URL: https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse Trace: 0x%d",
                      month, day, hour, minute, sec, offset)
    }.joined(separator: "\n")
    try Data(log.utf8).write(to: logDir.appendingPathComponent("cli-\(year)0101_000000.log"))

    let store = UsageStore()
    let collector = GeminiCollector(root: dir, dailyQuota: 100, historyFile: historyFile, logDir: logDir)
    collector.collect(into: store, now: now)
    #expect(store.geminiRequestDates.count == 3)
    #expect(store.limits[.gemini]?.first?.usedPercent == 3.0)
}
