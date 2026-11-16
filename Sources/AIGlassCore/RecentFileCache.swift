import CoreServices
import Foundation

/// `LogLocator.recentFiles` 결과를 캐시한다.
///
/// 배경: 갱신은 로그 파일이 바뀔 때마다(에이전트 활동 중 ~1초) 돈다. 매번 로그 폴더 전체(실측 파일 ~1만·폴더 ~4천)를
/// 다시 열거해 앱 CPU가 10~19%였다. 파일 내용 추가(append)는 목록을 바꾸지 않으므로, 목록은 캐시해 두고
/// 목록을 실제로 바꾸는 FSEvents 이벤트(새 파일·삭제·이름 변경, 이벤트 유실)나 TTL 만료 때만 다시 열거한다.
/// TTL은 이벤트로 알 수 없는 변화(8일보다 오래된 세션이 다시 쓰이기 시작함 등)를 늦게라도 잡기 위한 것이다.
///
/// 스레드: 열거는 백그라운드 수집기에서, `note`는 메인(FSEvents 콜백)에서 불린다 — 내부 잠금으로 보호.
public final class RecentFileCache: @unchecked Sendable {
    private struct Key: Hashable {
        let dir: String   // realpath로 정규화한 폴더 경로
        let suffix: String
        let days: Int
    }
    private struct Entry {
        let files: [URL]
        let paths: Set<String>
        let at: Date
    }

    private let ttl: TimeInterval
    private let clock: () -> Date
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    public init(ttl: TimeInterval = 120, clock: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.clock = clock
    }

    /// `dir` 아래에서 `suffix`로 끝나고 최근 N일 내 수정된 파일. 캐시가 유효하면 열거하지 않는다.
    public func files(under dir: URL, suffix: String, modifiedWithinDays days: Int = 8) -> [URL] {
        let key = Key(dir: Self.realPath(dir.path), suffix: suffix, days: days)
        let now = clock()
        lock.lock()
        if let entry = entries[key], now.timeIntervalSince(entry.at) < ttl {
            lock.unlock()
            return entry.files
        }
        lock.unlock()

        let files = LogLocator.recentFiles(under: URL(fileURLWithPath: key.dir, isDirectory: true),
                                           suffix: suffix, modifiedWithinDays: days)
        lock.lock()
        entries[key] = Entry(files: files, paths: Set(files.map(\.path)), at: now)
        lock.unlock()
        return files
    }

    /// FSEvents 이벤트 하나를 반영한다. 목록을 바꾸는 이벤트면 해당 캐시를 비운다.
    public func note(path: String, flags: UInt32) {
        let dropped = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags & dropped != 0 { invalidateAll(); return }

        let created = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let removed = flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
        let renamed = flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let isDir = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        guard created || removed || renamed else { return }

        let p = Self.canonicalEventPath(path)
        lock.lock()
        defer { lock.unlock() }
        for (key, entry) in entries where p.hasPrefix(key.dir + "/") {
            let known = entry.paths.contains(p)
            let changed: Bool
            if isDir {
                // 아는 파일을 품은 폴더가 지워졌거나 옮겨졌을 때, 또는 다른 곳에서 폴더가 옮겨져 들어왔을 때.
                // (새로 만든 빈 폴더는 안의 파일이 생길 때 따로 이벤트가 온다)
                changed = (removed || renamed) && entry.paths.contains { $0.hasPrefix(p + "/") }
                    || renamed && FileManager.default.fileExists(atPath: p)
            } else if known {
                // FSEvents는 방금 만든 파일에 덧붙일 때도 ItemCreated를 한동안 같이 보내고, 원자적 쓰기(임시 파일 → 이름 변경)는
                // 같은 경로에 Renamed를 보낸다 — 둘 다 목록은 그대로다. 실제로 사라졌을 때만 바뀐 것으로 본다.
                changed = (removed || renamed) && !FileManager.default.fileExists(atPath: p)
            } else {
                changed = (created || renamed) && p.hasSuffix(key.suffix)
            }
            if changed { entries[key] = nil }
        }
    }

    public func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// 심볼릭 링크를 푼 실제 경로 (FSEvents가 보내는 경로와 같은 형태 — 예: /var → /private/var).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 이벤트 경로 정규화. 삭제된 파일은 realpath가 실패하므로 부모 폴더만 푼다.
    static func canonicalEventPath(_ path: String) -> String {
        let ns = path as NSString
        return (realPath(ns.deletingLastPathComponent) as NSString).appendingPathComponent(ns.lastPathComponent)
    }
}
