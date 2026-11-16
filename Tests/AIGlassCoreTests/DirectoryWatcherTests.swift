import CoreServices
import Foundation
import Testing
@testable import AIGlassCore

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DirectoryWatcher.Event] = []
    func add(_ e: [DirectoryWatcher.Event]) { lock.lock(); events += e; lock.unlock() }
    var all: [DirectoryWatcher.Event] { lock.lock(); defer { lock.unlock() }; return events }
}

// 실제 FSEvents 스트림으로, 새 파일 이벤트가 경로·ItemCreated 플래그와 함께 콜백까지 오는지 본다.
// (RecentFileCache 무효화가 이 경로·플래그에 기댄다 — 비어 오면 새 세션 파일이 TTL(2분) 뒤에야 잡힌다)
@Test func deliversCreatedFileEventWithPathAndFlags() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let dir = RecentFileCache.realPath(base.path)
    let received = Received()
    let watcher = DirectoryWatcher(paths: [dir]) { received.add($0) }
    #expect(watcher != nil)
    try await Task.sleep(for: .milliseconds(300))   // 스트림 시작 직후 생성 이벤트를 놓치지 않게

    let file = (dir as NSString).appendingPathComponent("new.jsonl")
    try Data("{}\n".utf8).write(to: URL(fileURLWithPath: file))

    var match: DirectoryWatcher.Event?
    for _ in 0..<60 where match == nil {
        try await Task.sleep(for: .milliseconds(100))
        match = received.all.first { RecentFileCache.canonicalEventPath($0.path) == file }
    }
    let created = UInt32(kFSEventStreamEventFlagItemCreated)
    #expect(match != nil)
    #expect((match?.flags ?? 0) & created != 0)
    withExtendedLifetime(watcher) {}
}
