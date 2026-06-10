import Foundation
import Security

public struct ClaudeCredentials {
    public let accessToken: String

    /// Keychain 항목 "Claude Code-credentials"의 JSON payload 파싱
    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return ClaudeCredentials(accessToken: token)
    }

    /// macOS Keychain에서 Claude Code OAuth 자격증명 읽기 (최초 1회 사용자 허용 다이얼로그 표시됨)
    public static func fromKeychain() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return parse(data)
    }
}

public enum ClaudeUsageAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func parse(_ data: Data) -> [LimitWindow]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func window(_ key: String, kind: LimitWindow.Kind) -> LimitWindow? {
            guard let w = obj[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resets_at"] as? String).flatMap(ISO8601.date)
            return LimitWindow(kind: kind, usedPercent: used, resetsAt: resets)
        }
        var windows: [LimitWindow] = []
        if let five = window("five_hour", kind: .session5h) { windows.append(five) }
        if let week = window("seven_day", kind: .weekly) { windows.append(week) }
        return windows.isEmpty ? nil : windows
    }

    /// raw 응답도 함께 돌려줘서 --check-claude에서 실제 스키마를 눈으로 확인할 수 있게 한다.
    public static func fetch(token: String) async throws -> (windows: [LimitWindow]?, raw: Data) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (parse(data), data)
    }
}
