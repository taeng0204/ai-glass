import Foundation

@MainActor
public final class ClaudeCollector {
    private let root: URL
    private let reader = IncrementalLineReader()

    public init(root: URL) { self.root = root }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            // 토큰 줄만 String으로 만든다 — usage가 없는 줄(대화 본문 등)은 파싱도 안 한다.
            for line in reader.newLines(of: file, containing: "\"usage\"") {
                if let parsed = ClaudeLogParser.parse(line: line) {
                    batch.append(parsed)
                }
            }
        }
        if !batch.isEmpty { store.addEvents(batch) }
    }
}

@MainActor
public final class KimiCollector {
    private let root: URL
    private let reader = IncrementalLineReader()
    private var projectCache: [String: String?] = [:]

    public init(root: URL) { self.root = root }

    /// wire.jsonl 위치: `<session>/agents/<agent>/wire.jsonl` → 세션 폴더의 state.json에서 cwd를 읽는다.
    private func project(for file: URL) -> String? {
        let sessionDir = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let cached = projectCache[sessionDir.path] { return cached }
        let result = (try? Data(contentsOf: sessionDir.appendingPathComponent("state.json")))
            .flatMap { KimiLogParser.projectName(fromStateJSON: $0) }
        projectCache[sessionDir.path] = result
        return result
    }

    /// 새 이벤트가 추가됐으면 true (한도 즉시 갱신 트리거용).
    @discardableResult
    public func collect(into store: UsageStore) -> Bool {
        var batch: [(TokenEvent, String?)] = []
        for file in LogLocator.recentFiles(under: root, suffix: "wire.jsonl") {
            let proj = project(for: file)
            let fileKey = file.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            for line in reader.newLines(of: file, containing: "\"usage.record\"") {
                if let parsed = KimiLogParser.parse(line: line, fileKey: fileKey, project: proj) {
                    batch.append((parsed.event, parsed.key))
                }
            }
        }
        if !batch.isEmpty { store.addEvents(batch) }
        return !batch.isEmpty
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

    private func project(for file: URL) -> String? {
        let path = file.path
        if let cached = projectCache[path] { return cached }
        let result = CodexLogParser.projectName(ofFile: file)
        projectCache[path] = result
        return result
    }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        var latestLimits: [LimitWindow]?
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            let proj = project(for: file)
            // token_count 줄만 읽는다 — 세션 로그의 대부분(도구 출력·대화)은 건너뛴다.
            for line in reader.newLines(of: file, containing: "\"token_count\"") {
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
    /// Antigravity 대화 DB 디렉토리 (`~/.gemini/antigravity-cli/conversations`).
    private let conversationsDir: URL
    /// 파일경로별 마지막으로 적재한 idx (인스턴스 캐시). idx > 캐시인 레코드만 새로 적재.
    private var lastParsedIdx: [String: Int] = [:]
    /// 파일경로별 워크스페이스 캐시 (대화의 워크스페이스는 불변 — 성공만 캐시, 실패는 재시도).
    private var workspaceCache: [String: String] = [:]
    /// 파일경로별 마지막 스캔 시점의 콘텐츠 시그니처(db·wal mtime 최댓값).
    /// 변경 없는 db는 통째로 스킵 — refresh가 메인 스레드라 매 주기 전체 파싱은 프레임 드랍을 만든다.
    private var lastScanSignature: [String: Date] = [:]
    /// 요청 집계 소스(logs.json·log·history) 마지막 시그니처 + 그때 파싱한 날짜 캐시.
    /// 변경 없으면 30초마다 대용량 로그 재파싱을 건너뛴다 (now 의존 dailyWindow만 재계산).
    private var lastRequestSignature: Date?
    private var cachedRequestDates: [Date] = []
    /// false면 요청 수 기반 일일 추정 게이지를 게시하지 않는다 (실제 쿼터가 있을 때).
    public var publishesDailyEstimate = true

    public init(root: URL, dailyQuota: Int = 1000, historyFile: URL? = nil, logDir: URL? = nil,
                conversationsDir: URL? = nil) {
        self.root = root
        self.dailyQuota = dailyQuota
        self.historyFile = historyFile
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/history.jsonl")
        self.logDir = logDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/log")
        self.conversationsDir = conversationsDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli/conversations")
    }

    public func collect(into store: UsageStore, now: Date = Date()) {
        // 요청 소스(logs.json·log·history)가 직전과 동일하면 재파싱 스킵 — 캐시된 날짜 재사용.
        // (dailyWindow는 now 의존이라 항상 재계산하지만, 무거운 파일 읽기·JSON 파싱만 건너뜀.)
        let signature = requestSourcesSignature()
        var allDates: [Date]
        if let signature, signature == lastRequestSignature {
            allDates = cachedRequestDates
        } else {
            allDates = []
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
            cachedRequestDates = allDates
            lastRequestSignature = signature
        }
        store.setGeminiRequests(allDates)

        // Antigravity 대화 DB에서 토큰 이벤트 적재 (추정치, 비공개 포맷) — 추이·프로젝트 통계의 원천.
        // 한도 게시 여부와 무관하게 항상 실행한다. (실제 쿼터를 쓰는 동안 이 단계가 통째로 건너뛰어져
        // Antigravity가 추이·프로젝트에 안 잡히던 버그가 있었다.)
        collectConversationTokens(into: store)

        // agy /usage의 실제 쿼터를 받아오는 중이면 요청 수 기반 일일 추정치는 덮어쓰지 않는다.
        guard publishesDailyEstimate else { return }
        let window = GeminiLogParser.dailyWindow(requestDates: allDates, quota: dailyQuota, now: now)
        store.setLimits([window], for: .gemini)
    }

    /// 최근 8일 mtime의 `<convId>.db`를 READONLY로 읽어 새 generation을 TokenEvent로 적재한다.
    private func collectConversationTokens(into store: UsageStore) {
        // 폴백용 conversationId → 프로젝트 조인 (history.jsonl). 필요할 때 1회만 읽음.
        var projectMap: [String: String]?

        var batch: [(TokenEvent, String?)] = []
        for file in LogLocator.recentFiles(under: conversationsDir, suffix: ".db", modifiedWithinDays: 8) {
            let convId = (file.lastPathComponent as NSString).deletingPathExtension
            let path = file.path
            // 파싱 전 시그니처를 떠서, 변경 없는 db는 통째로 스킵 (파싱 중 쓰기는 다음 주기에 잡힘).
            let signature = Self.contentSignature(dbPath: path)
            if let signature, lastScanSignature[path] == signature { continue }
            let prevIdx = lastParsedIdx[path] ?? -1
            let gens = AntigravityConversationParser.generations(dbPath: path, afterIdx: prevIdx)
            if !gens.isEmpty {
                // 프로젝트: db 내부 trajectory_metadata_blob의 워크스페이스 우선, history 조인 폴백.
                var workspace = workspaceCache[path]
                if workspace == nil {
                    workspace = AntigravityConversationParser.workspace(dbPath: path)
                    if let workspace { workspaceCache[path] = workspace }
                }
                if workspace == nil, projectMap == nil {
                    projectMap = (try? Data(contentsOf: historyFile))
                        .map { AntigravityLogParser.conversationWorkspaces(jsonData: $0) } ?? [:]
                }
                let project = workspace ?? projectMap?[convId]
                var maxIdx = prevIdx
                for gen in gens {
                    if gen.idx > maxIdx { maxIdx = gen.idx }
                    let event = TokenEvent(
                        service: .gemini,
                        timestamp: gen.timestamp,
                        model: Self.normalizeModel(gen.model),
                        inputTokens: gen.inputTokens,
                        outputTokens: gen.outputTokens,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        project: project)
                    batch.append((event, "agy:\(convId):\(gen.idx)"))
                }
                lastParsedIdx[path] = maxIdx
            }
            if let signature { lastScanSignature[path] = signature }
        }
        if !batch.isEmpty { store.addEvents(batch) }
    }

    /// db 콘텐츠 변경 감지용 시그니처 — WAL 모드에선 쓰기가 `-wal`에 먼저 가므로
    /// `.db`와 `.db-wal` mtime의 최댓값을 쓴다. 조회 실패 시 nil(항상 스캔).
    /// 메인 스레드에서 매 주기 호출되므로 FileManager 대신 가벼운 stat(2)를 쓴다.
    nonisolated static func contentSignature(dbPath: String) -> Date? {
        switch (fileMtime(dbPath), fileMtime(dbPath + "-wal")) {
        case let (d?, w?): return max(d, w)
        case let (d?, nil): return d
        case let (nil, w?): return w
        case (nil, nil): return nil
        }
    }

    /// 단일 파일 mtime — FileManager보다 가벼운 stat(2). 없으면 nil.
    nonisolated static func fileMtime(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970:
            Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// 요청 집계 소스(logs.json·log·history)의 mtime 최댓값 — 변경 없으면 재파싱 스킵용.
    private func requestSourcesSignature() -> Date? {
        var paths = LogLocator.recentFiles(under: root, suffix: "logs.json", modifiedWithinDays: 8).map(\.path)
        paths += LogLocator.recentFiles(under: logDir, suffix: ".log", modifiedWithinDays: 8).map(\.path)
        paths.append(historyFile.path)
        var latest: Date?
        for p in paths {
            if let m = Self.fileMtime(p), latest == nil || m > latest! { latest = m }
        }
        return latest
    }

    /// Antigravity 표시명을 모델 식별자로 정규화한다.
    /// "Gemini 3.5 Flash (High)" → "gemini-3.5-flash" (괄호 제거 → 소문자 → 공백→하이픈).
    nonisolated static func normalizeModel(_ display: String) -> String {
        // 괄호 그룹 제거 (예: "(High)").
        var s = ""
        var depth = 0
        for ch in display {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { s.append(ch) }
        }
        let lowered = s.lowercased()
        let collapsed = lowered.split(separator: " ", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "antigravity" : collapsed
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
