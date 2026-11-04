import Foundation
import Testing
@testable import AIGlassCore

// MARK: - 헬퍼

private func tmpDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("aiglass-bf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func iso(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return f.string(from: d)
}

private func claudeLine(id: String, at date: Date, input: Int = 100) -> String {
    #"{"cwd":"/tmp/proj","type":"assistant","requestId":"req_\#(id)","timestamp":"\#(iso(date))","message":{"id":"msg_\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
}

private func codexLine(at date: Date, input: Int) -> String {
    #"{"timestamp":"\#(iso(date))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":\#(input + 5)}}}}"#
}

private func write(_ lines: [String], to url: URL, mtime: Date? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
}

private func sources(_ root: URL) -> HistoryBackfillSources {
    HistoryBackfillSources(
        claudeRoot: root.appendingPathComponent("claude"),
        codexRoot: root.appendingPathComponent("codex"),
        kimiRoot: root.appendingPathComponent("kimi"),
        antigravityConversations: root.appendingPathComponent("agy/conversations"),
        antigravityHistory: root.appendingPathComponent("agy/history.jsonl"))
}

private let day: TimeInterval = 24 * 3600

// MARK: - 필터링·중복 제거

@Test func backfillReadsOldLinesWithinLookbackButNotBeyond() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    // 20일 전(창 안) / 3일 전(창 안) / 60일 전(창 밖) 줄이 한 파일에 섞여 있다 (파일 mtime은 최근).
    try write([
        claudeLine(id: "old20", at: now.addingTimeInterval(-20 * day)),
        claudeLine(id: "new3", at: now.addingTimeInterval(-3 * day)),
        claudeLine(id: "ancient", at: now.addingTimeInterval(-60 * day)),
        #"{"type":"user","message":{"content":"usage 단어가 들어 있지만 토큰 줄이 아님"}}"#,
    ], to: sources(root).claudeRoot.appendingPathComponent("p/a.jsonl"))

    let events = HistoryBackfill.collectEvents(sources: sources(root), now: now)
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.service == .claude && $0.project == "proj" })
    // 8일 라이브 창보다 오래된 20일 전 줄도 읽힌다 — 이게 백필의 목적
    let oldest = events.map(\.timestamp).min()!
    #expect(now.timeIntervalSince(oldest) > 19 * day)
}

@Test func backfillSkipsFilesNotModifiedWithinLookback() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    // 내용의 시각은 최근이지만 파일 mtime이 60일 전 → 읽지 않는다 (비싼 순회 방지)
    try write([claudeLine(id: "x", at: now.addingTimeInterval(-1 * day))],
              to: sources(root).claudeRoot.appendingPathComponent("p/stale.jsonl"),
              mtime: now.addingTimeInterval(-60 * day))
    #expect(HistoryBackfill.collectEvents(sources: sources(root), now: now).isEmpty)
}

@Test func backfillDedupesRepeatedClaudeMessagesAcrossFiles() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let line = claudeLine(id: "dup", at: now.addingTimeInterval(-2 * day))
    try write([line, line], to: sources(root).claudeRoot.appendingPathComponent("p/a.jsonl"))
    try write([line], to: sources(root).claudeRoot.appendingPathComponent("p/b.jsonl")) // 이어받은 세션의 복사본
    #expect(HistoryBackfill.collectEvents(sources: sources(root), now: now).count == 1)
}

@Test func backfillCutsOffAtUTCMidnightOfOldestDay() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    // now를 UTC 정오로 고정: 35일 전 정오 줄은 그날 UTC 자정 이후라 포함, 36일 전 줄은 제외
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
    try write([
        claudeLine(id: "d35", at: now.addingTimeInterval(-35 * day)),
        claudeLine(id: "d36", at: now.addingTimeInterval(-36 * day)),
    ], to: sources(root).claudeRoot.appendingPathComponent("p/a.jsonl"), mtime: now)
    let events = HistoryBackfill.collectEvents(sources: sources(root), now: now)
    #expect(events.count == 1)
}

// MARK: - 서비스별 읽기

@Test func backfillReadsCodexWithProjectAndDedup() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let meta = #"{"type":"session_meta","payload":{"cwd":"/Users/me/hack-nas"}}"#
    let a = codexLine(at: now.addingTimeInterval(-10 * day), input: 1000)
    let b = codexLine(at: now.addingTimeInterval(-9 * day), input: 2000)
    try write([meta, a, a, b], to: sources(root).codexRoot.appendingPathComponent("2026/10/rollout-x.jsonl"))
    let events = HistoryBackfill.collectEvents(sources: sources(root), now: now).filter { $0.service == .codex }
    #expect(events.count == 2) // 같은 줄(a) 중복은 한 번만
    #expect(events.allSatisfy { $0.project == "hack-nas" })
}

@Test func backfillReadsKimiWithProjectFromState() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let session = sources(root).kimiRoot.appendingPathComponent("wd/sess1")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data(#"{"cwd":"/Users/me/dev/kimi-proj"}"#.utf8).write(to: session.appendingPathComponent("state.json"))
    let ms = Int64(now.addingTimeInterval(-5 * day).timeIntervalSince1970 * 1000)
    let rec = #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3.1-pro","usage":{"inputOther":500,"output":50,"inputCacheRead":0,"inputCacheCreation":0},"time":\#(ms)}"#
    try write([rec, rec], to: session.appendingPathComponent("agents/main/wire.jsonl"))
    let events = HistoryBackfill.collectEvents(sources: sources(root), now: now).filter { $0.service == .kimi }
    #expect(events.count == 1)
    #expect(events.first?.project == "kimi-proj")
}

@Test func backfillWithMissingRootsReturnsEmpty() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(HistoryBackfill.collectEvents(sources: sources(root)).isEmpty) // 아무 폴더도 없어도 크래시 없이 빈 결과
}

// MARK: - 스트리밍 줄 읽기

@Test func streamingReaderFindsMatchingLinesAcrossChunkBoundaries() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    // ~10MB: 4MB 청크 경계를 여러 번 넘고, 매칭 줄이 경계에 걸치도록 길이가 제각각인 필러 줄을 섞는다.
    var lines: [String] = []
    var total = 0
    var n = 0
    while total < 10 * 1024 * 1024 {
        let pad = String(repeating: "x", count: 1000 + (n * 7919) % 90_000) // 최대 ~91KB 줄
        lines.append(n % 25 == 0 ? "MATCH-\(n)-\(pad)" : "filler-\(n)-\(pad)")
        total += pad.utf8.count + 12
        n += 1
    }
    let expected = (0..<lines.count).filter { $0 % 25 == 0 }.map { "MATCH-\($0)-" }
    let file = root.appendingPathComponent("big.jsonl")
    try write(lines, to: file)

    var got: [String] = []
    HistoryBackfill.forEachLine(in: file, containing: "MATCH-") { line in
        got.append(String(line.prefix(line.firstIndex(of: "x").map { line.distance(from: line.startIndex, to: $0) } ?? 20)))
    }
    #expect(got == expected) // 하나도 빠지거나 중복되지 않고, 순서도 유지
}

@Test func streamingReaderHandlesLastLineWithoutNewlineAndHugeLine() throws {
    let root = try tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("tail.jsonl")
    // 청크(4MB)보다 큰 단일 줄(6MB) + 개행 없는 마지막 매칭 줄
    let huge = "MATCH-huge-" + String(repeating: "y", count: 6 * 1024 * 1024)
    try Data((huge + "\nplain\nMATCH-last").utf8).write(to: file)
    var got: [Int] = []
    HistoryBackfill.forEachLine(in: file, containing: "MATCH-") { got.append($0.utf8.count) }
    #expect(got.count == 2)
    #expect(got.first == huge.utf8.count)
    #expect(got.last == "MATCH-last".utf8.count)
}
