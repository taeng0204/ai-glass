import Foundation

/// macOS `security` 도구로 Keychain 일반 암호를 읽는다. 항목을 `security`로 만든 경우 그 도구가 신뢰 목록에 있어
/// 암호 대화상자가 뜨지 않는다 (앱이 SecItem으로 직접 읽으면 서명이 바뀔 때마다 암호창이 뜬다).
/// 프로세스를 띄우고 최대 `timeout`초 기다리므로 메인 스레드에서 부르지 않는다.
enum SecurityTool {
    static func findGenericPassword(service: String, account: String? = nil, timeout: TimeInterval = 2) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-w", "-s", service]
        if let account { arguments += ["-a", account] }
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
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
