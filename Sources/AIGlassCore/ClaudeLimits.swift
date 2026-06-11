import Foundation
import Security

public struct ClaudeCredentials {
    public let accessToken: String
    /// payload의 `claudeAiOauth.expiresAt`(epoch 밀리초)에서 파싱. 없으면 nil(무기한 캐시 가능).
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// Keychain 항목 "Claude Code-credentials"의 JSON payload 파싱
    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000.0)
        }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt)
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

    /// raw 응답과 HTTP 상태도 함께 돌려줘서 --check-claude에서 실제 스키마/인증 실패를 눈으로 확인할 수 있게 한다.
    public static func fetch(token: String) async throws -> (windows: [LimitWindow]?, raw: Data, statusCode: Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (parse(data), data, status)
    }
}

/// Keychain 자격증명을 메모리 캐시해 매 폴링마다 Keychain 다이얼로그가 뜨는 것을 막는다.
/// 캐시된 토큰이 만료(또는 만료 임박, now+60s)이거나 없을 때만 reader를 재호출한다.
@MainActor
public final class ClaudeTokenProvider {
    private let reader: () -> ClaudeCredentials?
    private var cached: ClaudeCredentials?

    /// 토큰 만료까지 이 여유(초) 이내면 만료로 간주하고 재조회한다.
    public var refreshLeeway: TimeInterval = 60

    /// - Parameter reader: Keychain 읽기 클로저. 테스트에서 주입 가능. 기본값은 실제 Keychain.
    public init(reader: @escaping () -> ClaudeCredentials? = { ClaudeCredentials.fromKeychain() }) {
        self.reader = reader
    }

    /// 유효한 액세스 토큰을 반환한다. 캐시가 유효하면 reader를 호출하지 않는다.
    public func token(now: Date = Date()) -> String? {
        if let cached, isFresh(cached, now: now) {
            return cached.accessToken
        }
        let fresh = reader()
        cached = fresh
        return fresh?.accessToken
    }

    /// 401 등으로 토큰이 거부되면 캐시를 비워 다음 호출에서 재조회하게 한다.
    public func invalidate() {
        cached = nil
    }

    private func isFresh(_ creds: ClaudeCredentials, now: Date) -> Bool {
        guard let expiresAt = creds.expiresAt else { return true } // 만료 정보 없으면 캐시 유지
        return expiresAt > now.addingTimeInterval(refreshLeeway)
    }
}
