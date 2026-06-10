import Foundation

@MainActor
public final class ClaudeCollector {
    private let root: URL
    private let reader = IncrementalLineReader()

    public init(root: URL) { self.root = root }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            for line in reader.newLines(of: file) {
                if let parsed = ClaudeLogParser.parse(line: line) {
                    batch.append(parsed)
                }
            }
        }
        if !batch.isEmpty { store.addEvents(batch) }
    }
}

@MainActor
public final class CodexCollector {
    private let root: URL
    private let reader = IncrementalLineReader()
    private var latestLimitsTimestamp: Date = .distantPast
    /// 파일 path → project name 캐시 (session_meta 기반).
    private var projectCache: [String: String?] = [:]

    public init(root: URL) { self.root = root }

    /// 파일의 첫 라인만 직접 읽어 session_meta 파싱 시도. IncrementalLineReader와 독립.
    private func readFirstLine(of file: URL) -> String? {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? fh.close() }
        // 첫 라인은 대부분 짧지만 최대 4KB 읽어 개행 탐색
        guard let data = try? fh.read(upToCount: 4096) else { return nil }
        if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            return String(data: data[data.startIndex..<newline], encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    private func project(for file: URL) -> String? {
        let path = file.path
        if let cached = projectCache[path] { return cached }
        let result: String? = readFirstLine(of: file).flatMap { CodexLogParser.parseSessionMeta(line: $0) }
        projectCache[path] = result
        return result
    }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        var latestLimits: [LimitWindow]?
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            let proj = project(for: file)
            for line in reader.newLines(of: file) {
                guard let parsed = CodexLogParser.parse(line: line) else { continue }
                if let event = parsed.event {
                    // rotation으로 오프셋이 리셋돼 같은 라인을 재파싱해도 중복 적재 방지
                    let key = "codex:\(file.lastPathComponent):\(parsed.timestamp.timeIntervalSince1970):\(event.totalTokens)"
                    let eventWithProject = TokenEvent(
                        service: event.service,
                        timestamp: event.timestamp,
                        model: event.model,
                        inputTokens: event.inputTokens,
                        outputTokens: event.outputTokens,
                        cacheReadTokens: event.cacheReadTokens,
                        cacheCreationTokens: event.cacheCreationTokens,
                        project: proj
                    )
                    batch.append((eventWithProject, key))
                }
                if !parsed.limits.isEmpty, parsed.timestamp > latestLimitsTimestamp {
                    latestLimitsTimestamp = parsed.timestamp
                    latestLimits = parsed.limits
                }
            }
        }
        if !batch.isEmpty { store.addEvents(batch) }
        if let latestLimits { store.setLimits(latestLimits, for: .codex) }
    }
}

@MainActor
public final class GeminiCollector {
    private let root: URL
    private let dailyQuota: Int

    public init(root: URL, dailyQuota: Int = 1000) {
        self.root = root
        self.dailyQuota = dailyQuota
    }

    public func collect(into store: UsageStore, now: Date = Date()) {
        var allDates: [Date] = []
        for file in LogLocator.recentFiles(under: root, suffix: "logs.json", modifiedWithinDays: 8) {
            guard let data = try? Data(contentsOf: file) else { continue }
            allDates.append(contentsOf: GeminiLogParser.userMessageDates(jsonData: data))
        }
        store.setGeminiRequests(allDates)
        let window = GeminiLogParser.dailyWindow(requestDates: allDates, quota: dailyQuota, now: now)
        store.setLimits([window], for: .gemini)
    }
}
