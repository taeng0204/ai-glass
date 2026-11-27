import Foundation

/// Claude Code를 Z.ai GLM Coding Plan으로 돌리는 설정 (`~/.claude/*.json` 중 `env.ANTHROPIC_BASE_URL`이 Z.ai인 파일).
/// GLM 전용 CLI가 없어서, 한도 API에 쓸 주소와 키를 Claude Code 설정에서 찾는다.
public struct ZaiConfig: Equatable, Sendable {
    public enum KeySource: Equatable, Sendable {
        /// 설정 파일의 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`.
        case token(String)
        /// `apiKeyHelper`가 `security find-generic-password -s <service> [-a <account>] -w`인 경우의 Keychain 항목.
        case keychain(service: String, account: String?)
    }

    public let quotaURL: URL
    /// nil = Z.ai 설정은 있지만 키를 안전하게 읽을 방법이 없다 (예: 임의 명령으로 된 apiKeyHelper).
    public let keySource: KeySource?

    /// 해외(Z.ai)·중국(BigModel) 리전. 이 호스트 그대로일 때만 인정한다 (비슷한 이름의 다른 호스트로 키를 보내지 않게).
    static let knownHosts: Set<String> = ["api.z.ai", "open.bigmodel.cn"]
    static let quotaPath = "/api/monitor/usage/quota/limit"

    /// `~/.claude` 바로 아래 JSON들을 이름순으로 보고, 키를 읽을 수 있는 Z.ai 설정을 우선 돌려준다.
    public static func find(home: URL) -> ZaiConfig? {
        let dir = home.appendingPathComponent(".claude")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var fallback: ZaiConfig?
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = dir.appendingPathComponent(name)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 1_000_000, let data = try? Data(contentsOf: file),
                  let config = parse(settingsJSON: data) else { continue }
            if config.keySource != nil { return config }
            if fallback == nil { fallback = config }
        }
        return fallback
    }

    static func parse(settingsJSON data: Data) -> ZaiConfig? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let env = obj["env"] as? [String: Any],
              let base = (env["ANTHROPIC_BASE_URL"] as? String).flatMap(URL.init(string:)),
              base.scheme == "https", let host = base.host?.lowercased(), knownHosts.contains(host),
              let quotaURL = URL(string: "https://\(host)\(quotaPath)") else { return nil }
        var source: KeySource?
        for key in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"] {
            if let token = env[key] as? String, !token.isEmpty { source = .token(token); break }
        }
        if source == nil, let helper = obj["apiKeyHelper"] as? String {
            source = keychainItem(fromHelper: helper)
        }
        return ZaiConfig(quotaURL: quotaURL, keySource: source)
    }

    /// `apiKeyHelper`가 Keychain 조회 한 줄일 때만 항목 이름을 꺼낸다. 명령 자체는 실행하지 않는다
    /// (설정 파일에 적힌 임의 명령을 앱이 대신 돌리지 않기 위해). 셸 문법(; | & $ 등)이 섞이면 거부한다.
    static func keychainItem(fromHelper helper: String) -> KeySource? {
        guard let words = shellWords(helper), words.count >= 2,
              (words[0] as NSString).lastPathComponent == "security",
              words[1] == "find-generic-password" else { return nil }
        var service: String?, account: String?, wantsPassword = false
        var i = 2
        while i < words.count {
            switch words[i] {
            case "-w": wantsPassword = true
            case "-s", "-a":
                guard i + 1 < words.count else { return nil }
                if words[i] == "-s" { service = words[i + 1] } else { account = words[i + 1] }
                i += 1
            default: return nil
            }
            i += 1
        }
        guard wantsPassword, let service, !service.isEmpty else { return nil }
        return .keychain(service: service, account: account)
    }

    /// 따옴표만 지원하는 최소 셸 단어 분리. 따옴표 밖의 셸 특수문자가 있으면 nil.
    private static func shellWords(_ s: String) -> [String]? {
        var words: [String] = [], current = "", inWord = false
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t":
                if inWord { words.append(current); current = ""; inWord = false }
            case ";", "|", "&", "$", "`", "<", ">", "\n", "(", ")", "\\", "*", "?", "~":
                return nil
            default: current.append(ch); inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(current) }
        return words
    }

    /// 키를 실제로 읽는다. Keychain 항목은 `security` 도구로 읽어 암호창이 뜨지 않게 한다 (Claude 토큰과 같은 방식).
    /// 프로세스를 띄우므로 메인 스레드에서 부르지 않는다.
    public func readKey() -> String? {
        switch keySource {
        case .token(let token): return token
        case .keychain(let service, let account):
            guard let data = SecurityTool.findGenericPassword(service: service, account: account),
                  let key = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
            return key
        case nil: return nil
        }
    }
}

/// GLM Coding Plan 한도 API (`GET /api/monitor/usage/quota/limit`). Z.ai 공식 사용량 조회 플러그인과 같은 엔드포인트.
public enum ZaiUsageAPI {
    public static let timeout: TimeInterval = 10

    /// 응답의 `data.limits[]` → 한도 창. 창 길이는 `unit` × `number`로 정해진다 (3 = 시간, 6 = 주, 5 = 월).
    /// 모델 사용량 한도(`TOKENS_LIMIT`·`CREDIT_LIMIT`)만 쓰고, MCP 도구 호출 횟수(`TIME_LIMIT`)와 길이를 모르는 창은 버린다.
    public static func parse(_ data: Data) -> [LimitWindow]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else { return nil }
        func number(_ dict: [String: Any], _ key: String) -> Double? { (dict[key] as? NSNumber)?.doubleValue }

        var windows: [LimitWindow] = []
        for limit in limits {
            guard let type = limit["type"] as? String, type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT",
                  let unit = number(limit, "unit"), let count = number(limit, "number"),
                  let kind = kind(unit: Int(unit), number: Int(count)) else { continue }
            let percent: Double
            if let total = number(limit, "usage"), total > 0, let used = number(limit, "currentValue") {
                percent = used / total * 100   // 정수로 반올림된 percentage보다 정밀하다
            } else if let p = number(limit, "percentage") {
                percent = p
            } else { continue }
            let resets = number(limit, "nextResetTime").map { Date(timeIntervalSince1970: $0 / 1000) }
            windows.append(LimitWindow(kind: kind, usedPercent: min(100, max(0, percent)), resetsAt: resets))
        }
        return windows.isEmpty ? nil : windows
    }

    static func kind(unit: Int, number: Int) -> LimitWindow.Kind? {
        switch (unit, number) {
        case (3, 5): return .session5h
        case (6, 1): return .weekly
        case (5, 1): return .monthly
        default: return nil
        }
    }

    /// 인증 헤더는 `Bearer` 없이 키 그대로 보낸다 (Z.ai 모니터 API 형식).
    public static func fetch(key: String, url: URL) async throws -> (windows: [LimitWindow]?, statusCode: Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (parse(data), status)
    }
}
