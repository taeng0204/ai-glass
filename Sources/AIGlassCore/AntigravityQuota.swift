import Foundation

/// Antigravity(`agy`) CLI의 `/usage` 출력에서 한도 창을 읽는다.
/// `agy -p "/usage" --output-format json` → `command.data.groups[].buckets[]`
/// (bucket: window "5h"/"weekly", remaining_fraction 0~1, reset_time ISO8601).
/// 모델을 호출하지 않고, 인증/토큰 갱신은 CLI가 처리하므로 AI Glass는 토큰을 건드리지 않는다.
public enum AntigravityQuota {
    /// 기준으로 삼을 모델 그룹 이름 (대소문자 무시 부분 일치).
    public static let defaultGroupMatch = "argon"

    /// JSON 응답 → 기준 그룹의 한도 창. 해당 그룹이 없거나 버킷이 없으면 nil.
    public static func parse(_ data: Data, groupMatch: String = defaultGroupMatch) -> [LimitWindow]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = obj["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else { return nil }
        let needle = groupMatch.lowercased()
        guard let group = groups.first(where: {
            (($0["name"] as? String) ?? "").lowercased().contains(needle)
        }), let buckets = group["buckets"] as? [[String: Any]] else { return nil }

        var windows: [LimitWindow] = []
        for bucket in buckets {
            let kind: LimitWindow.Kind
            switch bucket["window"] as? String {
            case "5h": kind = .session5h
            case "weekly": kind = .weekly
            default: continue
            }
            guard let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
            let resets = (bucket["reset_time"] as? String).flatMap(ISO8601.date)
            windows.append(LimitWindow(kind: kind,
                                       usedPercent: min(100, max(0, (1 - remaining) * 100)),
                                       resetsAt: resets))
        }
        return windows.isEmpty ? nil : windows
    }

    /// GUI 앱은 셸 PATH가 없으므로 흔한 설치 경로에서 agy를 찾는다.
    public static func locateExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    /// `agy -p "/usage" --output-format json` 실행 (백그라운드 스레드). 실패·타임아웃이면 nil.
    /// 로그는 임시 파일로 보내 `~/.gemini/antigravity-cli/log`에 파일이 쌓이거나 요청 집계가 오염되는 것을 막는다.
    public static func fetch(executable: URL, timeout: TimeInterval = 25) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("aiglass-agy-usage.log")
                try? FileManager.default.removeItem(at: logFile)
                let process = Process()
                process.executableURL = executable
                process.arguments = ["-p", "/usage", "--output-format", "json", "--log-file", logFile.path]
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(returning: nil); return }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                try? FileManager.default.removeItem(at: logFile)
                cont.resume(returning: process.terminationStatus == 0 && !data.isEmpty ? data : nil)
            }
        }
    }
}
