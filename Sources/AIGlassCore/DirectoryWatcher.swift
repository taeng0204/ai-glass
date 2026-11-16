import Foundation
import CoreServices

/// FSEvents로 디렉토리들을 감시. 변경 시 콜백 (메인 큐, 1초 latency 코얼레싱).
/// 콜백은 묶인 이벤트들의 경로·플래그를 받는다 — 파일 목록 캐시(RecentFileCache) 무효화 판단용.
public final class DirectoryWatcher {
    public struct Event: Sendable {
        public let path: String
        public let flags: UInt32
    }

    private var stream: FSEventStreamRef?
    private let callback: ([Event]) -> Void

    public init?(paths: [String], onChange: @escaping ([Event]) -> Void) {
        self.callback = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                // UseCFTypes 플래그라 eventPaths는 CFArray<CFString>.
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                var events: [Event] = []
                events.reserveCapacity(count)
                for i in 0..<min(count, paths.count) {
                    events.append(Event(path: paths[i], flags: eventFlags[i]))
                }
                DispatchQueue.main.async { watcher.callback(events) }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
