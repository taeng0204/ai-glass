import Foundation

public enum ClaudeLogParser {
    /// 홈 디렉토리 경로 주입 (테스트용). nil이면 `NSHomeDirectory()`.
    nonisolated(unsafe) public static var homeDirectoryOverride: String?

    /// cwd → 프로젝트명. cwd가 홈 디렉토리와 정확히 일치하면 "~", 아니면 lastPathComponent.
    static func project(forCwd cwd: String?) -> String? {
        guard let cwd else { return nil }
        let home = homeDirectoryOverride ?? NSHomeDirectory()
        if cwd == home { return "~" }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// 한 JSONL 라인 → 토큰 이벤트. usage가 없는 라인(user 메시지 등)은 nil.
    public static func parse(line: String) -> (event: TokenEvent, dedupKey: String?)? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = ISO8601.date(tsString)
        else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        guard model != "<synthetic>" else { return nil }

        func intValue(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }

        let project = self.project(forCwd: obj["cwd"] as? String)

        let event = TokenEvent(
            service: .claude,
            timestamp: timestamp,
            model: model,
            inputTokens: intValue("input_tokens"),
            outputTokens: intValue("output_tokens"),
            cacheReadTokens: intValue("cache_read_input_tokens"),
            cacheCreationTokens: intValue("cache_creation_input_tokens"),
            project: project
        )

        let messageID = message["id"] as? String
        let requestID = obj["requestId"] as? String
        let dedupKey: String? = (messageID != nil || requestID != nil)
            ? "\(messageID ?? ""):\(requestID ?? "")" : nil
        return (event, dedupKey)
    }
}
