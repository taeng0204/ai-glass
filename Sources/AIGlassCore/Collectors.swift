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
    /// session_meta 첫 줄은 payload.instructions(AGENTS.md 내용)로 수십 KB까지 커질 수 있어
    /// 64KB 청크로 반복 읽으며 개행을 찾는다. 상한 1MB 초과 시 nil.
    private func readFirstLine(of file: URL) -> String? {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? fh.close() }
        let chunkSize = 64 * 1024
        let maxBytes = 1024 * 1024
        var buffer = Data()
        while buffer.count < maxBytes {
            guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return String(data: buffer[buffer.startIndex..<newline], encoding: .utf8)
            }
        }
        // 상한 초과(개행 못 찾음) 시 nil, 그 외엔 전체를 한 줄로 간주
        if buffer.count >= maxBytes { return nil }
        return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
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
    /// Antigravity(agy) CLI 히스토리 파일. 작아서 매번 전체 재읽기.
    private let historyFile: URL
    /// Antigravity(agy) CLI 로그 디렉토리. 실제 모델 호출 수 추정에 사용.
    private let logDir: URL

    public init(root: URL, dailyQuota: Int = 1000, historyFile: URL? = nil, logDir: URL? = nil) {
        self.root = root
        self.dailyQuota = dailyQuota
        self.historyFile = historyFile
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/history.jsonl")
        self.logDir = logDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/log")
    }

    public func collect(into store: UsageStore, now: Date = Date()) {
        var allDates: [Date] = []
        // 기존 Gemini CLI 로그 (logs.json)
        for file in LogLocator.recentFiles(under: root, suffix: "logs.json", modifiedWithinDays: 8) {
            guard let data = try? Data(contentsOf: file) else { continue }
            allDates.append(contentsOf: GeminiLogParser.userMessageDates(jsonData: data))
        }

        // Antigravity 실제 모델 호출 로그가 오늘 있으면 우선 사용. 없으면 히스토리 프롬프트 수로 폴백.
        let agyModelRequests = antigravityModelRequestDates()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let hasTodayModelRequests = agyModelRequests.contains { $0 >= startOfDay && $0 <= now }
        if hasTodayModelRequests {
            allDates.append(contentsOf: agyModelRequests)
        } else if let data = try? Data(contentsOf: historyFile) {
            allDates.append(contentsOf: AntigravityLogParser.entries(jsonData: data).map(\.date))
        }
        store.setGeminiRequests(allDates)
        let window = GeminiLogParser.dailyWindow(requestDates: allDates, quota: dailyQuota, now: now)
        store.setLimits([window], for: .gemini)
    }

    private func antigravityModelRequestDates() -> [Date] {
        var dates: [Date] = []
        for file in LogLocator.recentFiles(under: logDir, suffix: ".log", modifiedWithinDays: 8) {
            guard let (year, month) = Self.yearMonth(fromLogFilename: file.lastPathComponent),
                  let data = try? Data(contentsOf: file) else { continue }
            dates.append(contentsOf: AntigravityLogParser.modelRequestDates(
                logData: data, year: year, fileStartMonth: month))
        }
        return dates
    }

    /// `cli-YYYYMMDD_HHMMSS.log`에서 생성 연·월을 추출. 월은 해 넘김 보정에 쓴다.
    private static func yearMonth(fromLogFilename filename: String) -> (year: Int, month: Int)? {
        guard filename.hasPrefix("cli-"), filename.count >= 12 else { return nil }
        let yStart = filename.index(filename.startIndex, offsetBy: 4)
        let yEnd = filename.index(yStart, offsetBy: 4)
        let mEnd = filename.index(yEnd, offsetBy: 2)
        guard let year = Int(filename[yStart..<yEnd]),
              let month = Int(filename[yEnd..<mEnd]) else { return nil }
        return (year, month)
    }
}
