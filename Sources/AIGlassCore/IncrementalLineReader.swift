import Foundation

/// 파일별 바이트 오프셋을 기억해 새로 추가된 완성 라인만 돌려준다.
///
/// 큰 파일도 메모리를 아끼도록 `StreamingLines`로 청크 단위로 읽는다. `marker`를 주면 그 문자열이 들어 있는
/// 줄만 돌려준다 — 토큰 줄이 전체의 일부인 로그(Codex·Claude)에서 `String` 생성과 JSON 파싱을 크게 줄인다.
/// 오프셋은 marker와 무관하게 읽은 만큼(완성된 줄 기준) 전진한다.
public final class IncrementalLineReader {
    private var offsets: [String: UInt64] = [:]

    public init() {}

    public func newLines(of url: URL, containing marker: String? = nil) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let key = url.path
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offsets[key] ?? 0
        if start > size { start = 0 } // 파일이 줄었다 = 교체/순환 → 처음부터
        guard size > start else { offsets[key] = size; return [] }

        var lines: [String] = []
        let consumed = StreamingLines.scan(handle, from: start, to: size, marker: marker.map { Array($0.utf8) },
                                           includeTrailing: false) { lines.append($0) }
        // 완성된 줄이 하나도 없으면(미완성 꼬리뿐) 오프셋을 그대로 둬서 다음에 이어 읽는다.
        if consumed > 0 { offsets[key] = start + consumed }
        return lines
    }
}
