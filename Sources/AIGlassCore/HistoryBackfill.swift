import Foundation

/// 과거 로그를 통계 DB에 채우기 위한 읽기 경로.
///
/// 라이브 수집기는 최근 8일만 읽고(`UsageStore.retentionDays`), 앱을 새로 설치하면 통계 DB도 그 8일치부터 시작한다.
/// 그래서 30일 추이·잔디에는 최근 것밖에 안 보였다. 이 백필은 더 긴 기간(기본 35일)의 로그를 한 번 읽어
/// `DailyStatsStore`(최댓값 병합)에만 채운다 — 라이브 화면의 8일 보관 정책은 건드리지 않는다.
///
/// - 메인 스레드를 막지 않도록 **상태 없는 정적 함수**로 만들었고(수집기는 @MainActor), 백그라운드에서 호출한다.
/// - Codex 세션 로그는 파일 하나가 300MB를 넘기도 해서, 통째로 읽지 않고 **4MB 청크 스트리밍 + 줄 단위 키워드
///   사전 필터**로 읽는다. JSON 파싱은 키워드가 있는 줄에만 한다.
public struct HistoryBackfillSources: Sendable {
    public let claudeRoot: URL
    public let codexRoot: URL
    public let kimiRoot: URL
    public let antigravityConversations: URL
    public let antigravityHistory: URL

    public init(claudeRoot: URL, codexRoot: URL, kimiRoot: URL,
                antigravityConversations: URL, antigravityHistory: URL) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.kimiRoot = kimiRoot
        self.antigravityConversations = antigravityConversations
        self.antigravityHistory = antigravityHistory
    }

    /// 라이브 수집기와 같은 기본 경로.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HistoryBackfillSources {
        HistoryBackfillSources(
            claudeRoot: home.appendingPathComponent(".claude/projects"),
            codexRoot: home.appendingPathComponent(".codex/sessions"),
            kimiRoot: home.appendingPathComponent(".kimi-code/sessions"),
            antigravityConversations: home.appendingPathComponent(".gemini/antigravity-cli/conversations"),
            antigravityHistory: home.appendingPathComponent(".gemini/antigravity-cli/history.jsonl"))
    }
}

public enum HistoryBackfill {
    /// 백필 로직 버전 — 올리면 이미 한 번 돌린 사용자도 다시 돌린다 (파서 수정으로 과거 데이터가 달라질 때).
    public static let version = 1
    /// 읽을 과거 일수. 30일 추이를 완전한 날짜로 채우려고 여유를 둔다.
    public static let lookbackDays = 35

    /// 최근 `lookbackDays`일의 토큰 이벤트를 전부 읽어 반환한다 (UTC 날짜 경계 기준으로 완전한 날만).
    /// 서비스·소스별 dedup 규칙은 라이브 수집기와 같다.
    public static func collectEvents(sources: HistoryBackfillSources, now: Date = Date(),
                                     lookbackDays: Int = HistoryBackfill.lookbackDays) -> [TokenEvent] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 가장 오래된 날의 UTC 자정부터 — 그날 일부만 읽어 부분합이 저장되는 일을 피한다.
        let cutoff = utc.startOfDay(for: now.addingTimeInterval(-Double(lookbackDays) * 24 * 3600))
        // 파일 mtime은 마지막 쓰기 시각이라, 컷오프보다 하루 더 여유를 둬 걸러낸다.
        let mtimeDays = lookbackDays + 1

        var events: [TokenEvent] = []
        events += claudeEvents(sources.claudeRoot, cutoff: cutoff, mtimeDays: mtimeDays)
        events += codexEvents(sources.codexRoot, cutoff: cutoff, mtimeDays: mtimeDays)
        events += kimiEvents(sources.kimiRoot, cutoff: cutoff, mtimeDays: mtimeDays)
        events += antigravityEvents(conversations: sources.antigravityConversations,
                                    history: sources.antigravityHistory, cutoff: cutoff, mtimeDays: mtimeDays)
        return events
    }

    // MARK: - 서비스별

    private static func claudeEvents(_ root: URL, cutoff: Date, mtimeDays: Int) -> [TokenEvent] {
        var out: [TokenEvent] = []
        var seen = Set<String>()
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl", modifiedWithinDays: mtimeDays) {
            forEachLine(in: file, containing: "\"usage\"") { line in
                guard let parsed = ClaudeLogParser.parse(line: line), parsed.event.timestamp >= cutoff else { return }
                if let key = parsed.dedupKey, !seen.insert(key).inserted { return }
                out.append(parsed.event)
            }
        }
        return out
    }

    private static func codexEvents(_ root: URL, cutoff: Date, mtimeDays: Int) -> [TokenEvent] {
        var out: [TokenEvent] = []
        var seen = Set<String>()
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl", modifiedWithinDays: mtimeDays) {
            let project = CodexLogParser.projectName(ofFile: file)
            forEachLine(in: file, containing: "\"token_count\"") { line in
                guard let parsed = CodexLogParser.parse(line: line), let event = parsed.event,
                      event.timestamp >= cutoff else { return }
                // 라이브 수집기와 같은 키 — 같은 줄이 다시 읽혀도 한 번만 센다
                let key = "codex:\(file.lastPathComponent):\(parsed.timestamp.timeIntervalSince1970):\(event.totalTokens)"
                guard seen.insert(key).inserted else { return }
                out.append(TokenEvent(service: event.service, timestamp: event.timestamp, model: event.model,
                                      inputTokens: event.inputTokens, outputTokens: event.outputTokens,
                                      cacheReadTokens: event.cacheReadTokens, cacheCreationTokens: event.cacheCreationTokens,
                                      project: project))
            }
        }
        return out
    }

    private static func kimiEvents(_ root: URL, cutoff: Date, mtimeDays: Int) -> [TokenEvent] {
        var out: [TokenEvent] = []
        var seen = Set<String>()
        for file in LogLocator.recentFiles(under: root, suffix: "wire.jsonl", modifiedWithinDays: mtimeDays) {
            // wire.jsonl 위치: <session>/agents/<agent>/wire.jsonl → 세션 폴더의 state.json에서 프로젝트
            let sessionDir = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let project = (try? Data(contentsOf: sessionDir.appendingPathComponent("state.json")))
                .flatMap { KimiLogParser.projectName(fromStateJSON: $0) }
            let fileKey = sessionDir.lastPathComponent
            forEachLine(in: file, containing: "\"usage.record\"") { line in
                guard let parsed = KimiLogParser.parse(line: line, fileKey: fileKey, project: project),
                      parsed.event.timestamp >= cutoff, seen.insert(parsed.key).inserted else { return }
                out.append(parsed.event)
            }
        }
        return out
    }

    private static func antigravityEvents(conversations: URL, history: URL, cutoff: Date, mtimeDays: Int) -> [TokenEvent] {
        var out: [TokenEvent] = []
        var projectMap: [String: String]?
        for file in LogLocator.recentFiles(under: conversations, suffix: ".db", modifiedWithinDays: mtimeDays) {
            let convId = (file.lastPathComponent as NSString).deletingPathExtension
            let gens = AntigravityConversationParser.generations(dbPath: file.path, afterIdx: -1)
                .filter { $0.timestamp >= cutoff }
            guard !gens.isEmpty else { continue }
            // 프로젝트: db 내부 워크스페이스 우선, history.jsonl 조인 폴백 (라이브 수집기와 같은 규칙)
            var workspace = AntigravityConversationParser.workspace(dbPath: file.path)
            if workspace == nil {
                if projectMap == nil {
                    projectMap = (try? Data(contentsOf: history))
                        .map { AntigravityLogParser.conversationWorkspaces(jsonData: $0) } ?? [:]
                }
                workspace = projectMap?[convId]
            }
            for gen in gens {
                out.append(TokenEvent(service: .gemini, timestamp: gen.timestamp,
                                      model: GeminiCollector.normalizeModel(gen.model),
                                      inputTokens: gen.inputTokens, outputTokens: gen.outputTokens,
                                      cacheReadTokens: 0, cacheCreationTokens: 0, project: workspace))
            }
        }
        return out
    }

    // MARK: - 스트리밍 줄 읽기

    /// 파일을 4MB 청크로 읽어 줄 단위로 훑고, `marker` 바이트열이 들어 있는 줄만 String으로 만들어 `body`에 넘긴다.
    /// 메모리는 청크 + 걸쳐 있는 한 줄 정도만 쓴다 (300MB 파일도 안전). 마지막 줄이 개행으로 끝나지 않으면
    /// 쓰는 중이던 잘린 줄일 수 있으니, 파싱 실패로 자연스럽게 걸러지게 두고 그대로 넘긴다.
    static func forEachLine(in url: URL, containing marker: String, _ body: (String) -> Void) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let needle = Array(marker.utf8)
        var carry = Data()

        func emit(_ base: UnsafeRawPointer, _ start: Int, _ len: Int) {
            guard len >= needle.count else { return }
            let found = needle.withUnsafeBytes { memmem(base + start, len, $0.baseAddress, needle.count) }
            guard found != nil,
                  let line = String(data: Data(bytes: base + start, count: len), encoding: .utf8) else { return }
            body(line)
        }

        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            var buf = carry
            buf.append(chunk)
            let consumed: Int = buf.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                let total = raw.count
                var start = 0
                while start < total, let nl = memchr(base + start, 0x0A, total - start) {
                    let end = base.distance(to: UnsafeRawPointer(nl))
                    emit(base, start, end - start)
                    start = end + 1
                }
                return start
            }
            carry = consumed < buf.count ? Data(buf.suffix(from: buf.startIndex + consumed)) : Data()
        }
        if !carry.isEmpty {
            carry.withUnsafeBytes { raw in
                if let base = raw.baseAddress { emit(base, 0, raw.count) }
            }
        }
    }
}
