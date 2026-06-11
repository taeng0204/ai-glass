import Foundation
import Security
import LocalAuthentication

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

    /// macOS Keychain에서 Claude Code OAuth 자격증명 읽기.
    public static func fromKeychain() -> ClaudeCredentials? {
        if let data = readKeychainDataWithoutPrompt() {
            return parse(data)
        }
        if let data = readKeychainDataWithSecurityTool() {
            return parse(data)
        }
        return nil
    }

    /// 앱 번들 재서명 후 Keychain ACL이 UI 승인을 요구하면 즉시 실패시켜 폴링이 멈추지 않게 한다.
    private static func readKeychainDataWithoutPrompt() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    /// ad-hoc 서명 앱이 직접 접근 권한을 잃은 경우, macOS `security` 도구로 동일 항목을 읽어 폴백한다.
    private static func readKeychainDataWithSecurityTool() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Claude Code-credentials"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}

public enum ClaudeUsageAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let timeout: TimeInterval = 10

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
        let request = request(token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        return decode(data: data, response: response)
    }

    /// 커맨드라인 진단에서는 AppKit runloop가 없으므로 async Task 대신 완료 콜백으로 직접 대기한다.
    public static func fetchSynchronously(token: String) throws -> (windows: [LimitWindow]?, raw: Data, statusCode: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(windows: [LimitWindow]?, raw: Data, statusCode: Int), Error>?
        let task = URLSession.shared.dataTask(with: request(token: token)) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(decode(data: data ?? Data(), response: response))
            }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 2) == .success else {
            task.cancel()
            throw URLError(.timedOut)
        }
        return try result?.get() ?? decode(data: Data(), response: nil)
    }

    private static func request(token: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func decode(data: Data, response: URLResponse?) -> (windows: [LimitWindow]?, raw: Data, statusCode: Int) {
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
