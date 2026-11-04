import Foundation

/// 큰 로그 파일을 메모리를 아끼며 줄 단위로 훑는 공용 스캐너 (라이브 수집기·과거 백필 공용).
///
/// 이전 구현은 파일(또는 새로 늘어난 부분) 전체를 `Data` → `String` → `split` → `map(String.init)`로 복사해,
/// 300MB짜리 Codex 세션 로그 하나에 순간 메모리가 1GB 가까이 늘고 모든 줄을 JSON 파싱했다.
/// 여기서는 4MB 청크로 읽고, `marker`가 들어 있는 줄만 `String`으로 만들어 넘긴다.
/// 메모리는 청크 + 청크에 걸친 한 줄 정도만 쓴다.
enum StreamingLines {
    static let chunkSize = 4 << 20

    /// `[start, end)` 구간을 읽어 줄 단위로 `body`에 넘긴다.
    /// - Parameters:
    ///   - marker: nil이 아니면 이 바이트열이 들어 있는 줄만 넘긴다 (빈 줄은 항상 건너뜀).
    ///   - includeTrailing: true면 개행으로 끝나지 않은 마지막 줄도 넘긴다 (정적 파일 백필용).
    ///     false면 완성된 줄(개행까지)만 넘기고 미완성 꼬리는 소비하지 않는다 (쓰는 중인 파일용).
    /// - Returns: 소비한 바이트 수 — `includeTrailing == false`면 마지막 개행 바로 뒤까지.
    @discardableResult
    static func scan(_ handle: FileHandle, from start: UInt64, to end: UInt64, marker: [UInt8]?,
                     includeTrailing: Bool, _ body: (String) -> Void) -> UInt64 {
        guard end > start, (try? handle.seek(toOffset: start)) != nil else { return 0 }

        func emit(_ base: UnsafeRawPointer, _ offset: Int, _ len: Int) {
            guard len > 0 else { return }
            if let marker {
                guard len >= marker.count else { return }
                let hit = marker.withUnsafeBytes { memmem(base + offset, len, $0.baseAddress, marker.count) }
                guard hit != nil else { return }
            }
            // 깨진 UTF-8도 치환 문자로 살린다 (이전 구현과 같은 관용).
            body(String(decoding: UnsafeRawBufferPointer(start: base + offset, count: len), as: UTF8.self))
        }

        var consumed: UInt64 = 0
        var position = start
        var carry = Data()
        var reachedEOF = false
        while position < end, !reachedEOF {
            // `FileHandle.read`가 돌려주는 Data는 autorelease 풀에 걸려, 이 루프가 끝날 때까지(= 파일 전체를 읽을 때까지)
            // 해제되지 않았다 (314MB 파일에서 최대 메모리가 +365MB). 청크마다 풀을 비워 4MB 단위로 되돌린다.
            autoreleasepool {
                let want = Int(min(UInt64(chunkSize), end - position))
                guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { reachedEOF = true; return }
                position += UInt64(chunk.count)

                var buf = carry
                buf.append(chunk)
                let used: Int = buf.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    let total = raw.count
                    var lineStart = 0
                    while lineStart < total, let nl = memchr(base + lineStart, 0x0A, total - lineStart) {
                        let lineEnd = base.distance(to: UnsafeRawPointer(nl))
                        emit(base, lineStart, lineEnd - lineStart)
                        lineStart = lineEnd + 1
                    }
                    return lineStart
                }
                consumed += UInt64(used)
                carry = used < buf.count ? Data(buf.suffix(from: buf.startIndex + used)) : Data()
            }
        }

        if includeTrailing, !carry.isEmpty {
            carry.withUnsafeBytes { raw in
                if let base = raw.baseAddress { emit(base, 0, raw.count) }
            }
            consumed += UInt64(carry.count)
        }
        return consumed
    }
}
