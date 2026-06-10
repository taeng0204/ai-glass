import Foundation

/// 파일별 바이트 오프셋을 기억해 새로 추가된 완성 라인만 돌려준다.
public final class IncrementalLineReader {
    private var offsets: [String: UInt64] = [:]

    public init() {}

    public func newLines(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let key = url.path
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offsets[key] ?? 0
        if start > size { start = 0 } // 파일이 줄었다 = 교체/순환 → 처음부터
        guard size > start else { offsets[key] = size; return [] }

        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // 완성된 줄(\n까지)만 소비하고 오프셋 전진
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let consumed = data[data.startIndex...lastNewline]
        offsets[key] = start + UInt64(consumed.count)
        return String(decoding: consumed, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
