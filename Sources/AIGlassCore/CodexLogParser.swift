import Foundation

public struct CodexParsed: Equatable {
    public let timestamp: Date
    public let event: TokenEvent?       // info가 null이면 nil
    public let limits: [LimitWindow]    // primary→session5h, secondary→weekly
}

public enum CodexLogParser {
    public static func parse(line: String) -> CodexParsed? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let tsString = obj["timestamp"] as? String,
              let timestamp = ISO8601.date(tsString)
        else { return nil }

        var limits: [LimitWindow] = []
        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            func window(_ key: String, kind: LimitWindow.Kind) -> LimitWindow? {
                guard let w = rateLimits[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let resets = (w["resets_in_seconds"] as? NSNumber).map {
                    timestamp.addingTimeInterval($0.doubleValue)
                }
                return LimitWindow(kind: kind, usedPercent: used, resetsAt: resets)
            }
            if let p = window("primary", kind: .session5h) { limits.append(p) }
            if let s = window("secondary", kind: .weekly) { limits.append(s) }
        }

        var event: TokenEvent?
        if let info = payload["info"] as? [String: Any],
           let last = info["last_token_usage"] as? [String: Any] {
            func intValue(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
            let cached = intValue("cached_input_tokens")
            event = TokenEvent(
                service: .codex,
                timestamp: timestamp,
                model: "gpt-codex",
                inputTokens: max(0, intValue("input_tokens") - cached),
                outputTokens: intValue("output_tokens"),
                cacheReadTokens: cached,
                cacheCreationTokens: 0
            )
        }
        return CodexParsed(timestamp: timestamp, event: event, limits: limits)
    }
}
