import Foundation

/// 과거 로그를 통계 DB에 채우기 위한 읽기 경로.
///
/// 라이브 수집기는 최근 8일만 읽고(`UsageStore.retentionDays`), 앱을 새로 설치하면 통계 DB도 그 8일치부터 시작한다.
/// 그래서 30일 추이·잔디에는 최근 것밖에 안 보였다. 이 백필은 더 긴 기간(기본 110일)의 로그를 한 번 읽어
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
    /// (v2: 읽는 기간을 35일 → 110일로 늘림 — 잔디 15주(≈105일)를 채우려고.)
    public static let version = 2
    /// 읽을 과거 일수. 가장 긴 화면이 잔디(15주 = 최대 약 104일)라서 그만큼 + 여유.
    /// 30일 추이(30일)와 7일 화면은 그 안에 포함된다.
    public static let lookbackDays = 110

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

    /// 파일을 `StreamingLines`로 훑어, `marker`가 들어 있는 줄만 `body`에 넘긴다 (정적 파일이라 마지막 줄도 포함).
    /// 쓰는 중이던 잘린 마지막 줄은 파싱 실패로 자연스럽게 걸러진다.
    static func forEachLine(in url: URL, containing marker: String, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        StreamingLines.scan(handle, from: 0, to: size, marker: Array(marker.utf8), includeTrailing: true, body)
    }
}
