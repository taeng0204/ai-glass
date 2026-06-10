import Foundation

public enum ClaudeLogParser {
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

        let event = TokenEvent(
            service: .claude,
            timestamp: timestamp,
            model: model,
            inputTokens: intValue("input_tokens"),
            outputTokens: intValue("output_tokens"),
            cacheReadTokens: intValue("cache_read_input_tokens"),
            cacheCreationTokens: intValue("cache_creation_input_tokens")
        )

        let messageID = message["id"] as? String
        let requestID = obj["requestId"] as? String
        let dedupKey: String? = (messageID != nil || requestID != nil)
            ? "\(messageID ?? ""):\(requestID ?? "")" : nil
        return (event, dedupKey)
    }
}
