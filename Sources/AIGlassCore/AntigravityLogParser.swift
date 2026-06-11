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

    /// Antigravity CLI 로그에서 실제 모델 요청(`streamGenerateContent`) 시각을 추출한다.
    /// 로그 라인은 `I0611 23:20:50.123456 ... streamGenerateContent ...` 형식이고,
    /// 파일명(`cli-YYYYMMDD_HHMMSS.log`)에서 year를 주입받는다.
    public static func modelRequestDates(logData: Data, year: Int,
                                         calendar: Calendar = .current) -> [Date] {
        guard let text = String(data: logData, encoding: .utf8) else { return [] }
        var result: [Date] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.contains("streamGenerateContent") else { continue }
            let line = String(rawLine)
            guard line.count >= 22 else { continue }
            let chars = Array(line)
            guard chars[1].isNumber, chars[2].isNumber, chars[3].isNumber, chars[4].isNumber,
                  chars[6].isNumber, chars[7].isNumber,
                  chars[9].isNumber, chars[10].isNumber,
                  chars[12].isNumber, chars[13].isNumber,
                  chars[15].isNumber, chars[16].isNumber
            else { continue }

            let month = Int(String(chars[1...2])) ?? 0
            let day = Int(String(chars[3...4])) ?? 0
            let hour = Int(String(chars[6...7])) ?? 0
            let minute = Int(String(chars[9...10])) ?? 0
            let second = Int(String(chars[12...13])) ?? 0
            var components = DateComponents()
            components.calendar = calendar
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            if let date = calendar.date(from: components) {
                result.append(date)
            }
        }
        return result
    }
}
