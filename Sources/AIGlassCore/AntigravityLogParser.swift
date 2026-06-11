import Foundation

/// Antigravity(agy) CLI 히스토리(`~/.gemini/antigravity-cli/history.jsonl`) 파서.
/// 각 줄: `{"display":"...","timestamp":<epoch ms>,"workspace":"/path","conversationId":"..."}`.
/// workspace/conversationId는 없을 수 있으므로 방어적으로 파싱한다.
public enum AntigravityLogParser {
    /// 홈 디렉토리 경로 주입 (테스트용). nil이면 `NSHomeDirectory()`.
    nonisolated(unsafe) public static var homeDirectoryOverride: String?

    /// JSONL 데이터(파일 전체)를 줄 단위로 파싱한다.
    /// timestamp(ms)→Date, workspace→lastPathComponent(홈과 일치 시 "~"). 손상 라인은 무시.
    public static func entries(jsonData: Data) -> [(date: Date, project: String?)] {
        guard let text = String(data: jsonData, encoding: .utf8) else { return [] }
        var result: [(date: Date, project: String?)] = []
        let home = homeDirectoryOverride ?? NSHomeDirectory()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ms = (obj["timestamp"] as? NSNumber)?.doubleValue
            else { continue }
            let date = Date(timeIntervalSince1970: ms / 1000.0)
            var project: String? = nil
            if let workspace = obj["workspace"] as? String, !workspace.isEmpty {
                if workspace == home {
                    project = "~"
                } else {
                    let last = (workspace as NSString).lastPathComponent
                    project = last.isEmpty ? nil : last
                }
            }
            result.append((date: date, project: project))
        }
        return result
    }
}
