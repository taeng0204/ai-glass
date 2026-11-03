import Foundation

/// Kimi Code OAuth 자격증명 (`~/.kimi-code/credentials/*.json`).
/// 액세스 토큰 수명이 15분이라, AI Glass는 갱신하지 않고 Kimi CLI가 갱신해 둔 값만 쓴다
/// (refresh_token을 쓰면 CLI 로그인이 풀릴 수 있음). 만료됐으면 nil.
public struct KimiCredentials {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public static func parse(_ data: Data) -> KimiCredentials? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty else { return nil }
        var expiresAt: Date?
        if let raw = (obj["expires_at"] as? NSNumber)?.doubleValue {
            // 초 또는 밀리초 둘 다 방어.
            expiresAt = Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000.0 : raw)
        }
        return KimiCredentials(accessToken: token, expiresAt: expiresAt)
    }

    /// 가장 최근에 수정된 자격증명 파일에서 아직 유효한(만료 여유 `leeway`초) 토큰을 읽는다.
    public static func loadValid(home: URL, now: Date = Date(), leeway: TimeInterval = 30) -> KimiCredentials? {
        let dir = home.appendingPathComponent(".kimi-code/credentials")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in newest {
            guard let data = try? Data(contentsOf: file), let creds = parse(data) else { continue }
            if let exp = creds.expiresAt, exp <= now.addingTimeInterval(leeway) { continue }
            return creds
        }
        return nil
    }
}

public enum KimiUsageAPI {
    public static let defaultBase = "https://api.kimi.com/coding/v1"
    public static let globalBase = "https://api.kimi.ai/coding/v1"
    public static let timeout: TimeInterval = 10

    /// config.toml의 `[providers."managed:kimi-code"]` 섹션 `base_url`, 없으면 region 파일("global")로 판단.
    public static func baseURL(home: URL) -> URL {
        let root = home.appendingPathComponent(".kimi-code")
        if let toml = try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8),
           let url = baseURL(fromConfigTOML: toml) { return url }
        let region = (try? String(contentsOf: root.appendingPathComponent("region"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: region == "global" ? globalBase : defaultBase)!
    }

    static func baseURL(fromConfigTOML toml: String) -> URL? {
        var inSection = false
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = (line == "[providers.\"managed:kimi-code\"]")
                continue
            }
            guard inSection, line.hasPrefix("base_url") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let url = URL(string: value), url.scheme == "https" { return url }
        }
        return nil
    }

    /// `/usages` 응답 → 한도 창. `usages.limit_5h` / `limit_7d` / `limit_month_total`의
    /// `used_ratio`(0~1)와 `reset_time`(ISO8601). 7일 창은 신규 플랜에는 없을 수 있다.
    public static func parse(_ data: Data) -> [LimitWindow]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usages = obj["usages"] as? [String: Any] else { return nil }
        func window(_ key: String, kind: LimitWindow.Kind) -> LimitWindow? {
            guard let w = usages[key] as? [String: Any] else { return nil }
            let ratio: Double
            if let n = w["used_ratio"] as? NSNumber { ratio = n.doubleValue }
            else if let s = w["used_ratio"] as? String, let d = Double(s) { ratio = d }
            else { return nil }
            let resets = (w["reset_time"] as? String).flatMap(ISO8601.date)
            return LimitWindow(kind: kind, usedPercent: min(100, max(0, ratio * 100)), resetsAt: resets)
        }
        var windows: [LimitWindow] = []
        if let w = window("limit_5h", kind: .session5h) { windows.append(w) }
        if let w = window("limit_7d", kind: .weekly) { windows.append(w) }
        if let w = window("limit_month_total", kind: .monthly) { windows.append(w) }
        return windows.isEmpty ? nil : windows
    }

    public static func fetch(token: String, base: URL) async throws -> (windows: [LimitWindow]?, statusCode: Int) {
        var request = URLRequest(url: base.appendingPathComponent("usages"), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (parse(data), status)
    }
}
