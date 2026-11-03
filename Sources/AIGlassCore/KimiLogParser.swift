import Foundation

/// Kimi Code 세션 로그(`~/.kimi-code/sessions/<wd>/<session>/agents/<agent>/wire.jsonl`) 파서.
/// 토큰 사용량은 `usage.record` 이벤트에 있다 (모델, inputOther/output/inputCacheRead/inputCacheCreation, 밀리초 시각).
public enum KimiLogParser {
    /// `usage.record` 한 줄 → TokenEvent + 중복 방지 키. 해당 이벤트가 아니거나 토큰이 0이면 nil.
    /// - Parameters:
    ///   - fileKey: 중복 키에 넣을 파일 식별자 (세션 id 등).
    ///   - project: 세션 작업 디렉터리 이름.
    public static func parse(line: String, fileKey: String, project: String?) -> (event: TokenEvent, key: String)? {
        // 대부분의 줄은 usage.record가 아니므로 JSON 파싱 전에 값싼 검사로 거른다.
        guard line.contains("\"usage.record\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "usage.record",
              let usage = obj["usage"] as? [String: Any],
              let ms = (obj["time"] as? NSNumber)?.doubleValue else { return nil }

        func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let input = int("inputOther"), output = int("output")
        let cacheRead = int("inputCacheRead"), cacheCreate = int("inputCacheCreation")
        guard input + output + cacheRead + cacheCreate > 0 else { return nil }

        let model = (obj["model"] as? String) ?? "kimi"
        let agent = (obj["agentId"] as? String) ?? "main"
        let event = TokenEvent(service: .kimi,
                               timestamp: Date(timeIntervalSince1970: ms / 1000.0),
                               model: model,
                               inputTokens: input, outputTokens: output,
                               cacheReadTokens: cacheRead, cacheCreationTokens: cacheCreate,
                               project: project)
        return (event, "kimi:\(fileKey):\(agent):\(Int64(ms))")
    }

    /// 세션 `state.json`에서 작업 디렉터리 이름(cwd의 마지막 경로 요소)을 읽는다.
    public static func projectName(fromStateJSON data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
