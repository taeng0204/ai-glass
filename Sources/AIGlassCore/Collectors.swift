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

    public init(root: URL) { self.root = root }

    public func collect(into store: UsageStore) {
        var batch: [(TokenEvent, String?)] = []
        var latestLimits: [LimitWindow]?
        for file in LogLocator.recentFiles(under: root, suffix: ".jsonl") {
            for line in reader.newLines(of: file) {
                guard let parsed = CodexLogParser.parse(line: line) else { continue }
                if let event = parsed.event {
                    // rotation으로 오프셋이 리셋돼 같은 라인을 재파싱해도 중복 적재 방지
                    let key = "codex:\(file.lastPathComponent):\(parsed.timestamp.timeIntervalSince1970):\(event.totalTokens)"
                    batch.append((event, key))
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
