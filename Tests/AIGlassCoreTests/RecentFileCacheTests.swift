import CoreServices
import Foundation
import Testing
@testable import AIGlassCore

// 배경: 갱신마다(에이전트 활동 중 ~1초) 로그 폴더 전체(실측 파일 ~1만·폴더 ~4천)를 다시 열거해 CPU 10~19%.
// 목록은 캐시하고, 목록을 실제로 바꾸는 이벤트(새 파일·삭제·이름 변경)나 TTL 만료 때만 다시 열거한다.

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private final class Clock: @unchecked Sendable {
    var now = Date()
}

private let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
private let createdAndModified = created | UInt32(kFSEventStreamEventFlagItemModified)
private let removed = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)

private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

@Test func reusesListWithinTTLWithoutReEnumerating() throws {
    let dir = try tempDir()
    try Data().write(to: dir.appendingPathComponent("a.jsonl"))
    let clock = Clock()
    let cache = RecentFileCache(ttl: 120, clock: { clock.now })
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["a.jsonl"])

    // 이벤트 없이 디스크에만 생긴 파일은 TTL 안에서는 보이지 않는다 (= 다시 열거하지 않았다는 증거)
    try Data().write(to: dir.appendingPathComponent("b.jsonl"))
    clock.now += 60
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["a.jsonl"])
}

@Test func reEnumeratesAfterTTL() throws {
    let dir = try tempDir()
    try Data().write(to: dir.appendingPathComponent("a.jsonl"))
    let clock = Clock()
    let cache = RecentFileCache(ttl: 120, clock: { clock.now })
    _ = cache.files(under: dir, suffix: ".jsonl")
    try Data().write(to: dir.appendingPathComponent("b.jsonl"))
    clock.now += 121
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["a.jsonl", "b.jsonl"])
}

@Test func newMatchingFileEventInvalidatesList() throws {
    let dir = try tempDir()
    try Data().write(to: dir.appendingPathComponent("a.jsonl"))
    let cache = RecentFileCache(ttl: 120)
    _ = cache.files(under: dir, suffix: ".jsonl")
    let b = dir.appendingPathComponent("b.jsonl")
    try Data().write(to: b)
    cache.note(path: b.path, flags: created)
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["a.jsonl", "b.jsonl"])
}

@Test func createdFlagOnAlreadyKnownFileDoesNotInvalidate() throws {
    // FSEvents는 방금 만든 파일에 덧붙여 쓸 때도 한동안 ItemCreated 플래그를 같이 보낸다.
    // 이미 목록에 있는 파일이면 목록이 바뀐 게 아니다 — 매 append마다 다시 열거하면 캐시가 무의미하다.
    let dir = try tempDir()
    let a = dir.appendingPathComponent("a.jsonl")
    try Data().write(to: a)
    let cache = RecentFileCache(ttl: 120)
    _ = cache.files(under: dir, suffix: ".jsonl")
    try Data().write(to: dir.appendingPathComponent("c.jsonl")) // 이벤트 없이 생긴 파일 — 다시 열거하면 보인다
    cache.note(path: a.path, flags: createdAndModified)
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["a.jsonl"])
}

@Test func unrelatedFileEventsDoNotInvalidate() throws {
    // SQLite 저널·임시 파일 같은 다른 확장자, 다른 폴더의 이벤트는 무시한다.
    let dir = try tempDir()
    let other = try tempDir()
    try Data().write(to: dir.appendingPathComponent("a.db"))
    let cache = RecentFileCache(ttl: 120)
    _ = cache.files(under: dir, suffix: ".db")
    try Data().write(to: dir.appendingPathComponent("b.db"))
    cache.note(path: dir.appendingPathComponent("a.db-journal").path, flags: created)
    cache.note(path: other.appendingPathComponent("z.db").path, flags: created)
    #expect(names(cache.files(under: dir, suffix: ".db")) == ["a.db"])
}

@Test func removingKnownFileInvalidatesList() throws {
    let dir = try tempDir()
    let a = dir.appendingPathComponent("a.jsonl")
    try Data().write(to: a)
    try Data().write(to: dir.appendingPathComponent("b.jsonl"))
    let cache = RecentFileCache(ttl: 120)
    #expect(cache.files(under: dir, suffix: ".jsonl").count == 2)
    try FileManager.default.removeItem(at: a)
    cache.note(path: a.path, flags: removed)
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["b.jsonl"])
}

@Test func droppedEventsInvalidateEverything() throws {
    // 커널/사용자 쪽에서 이벤트가 유실되면(MustScanSubDirs 등) 무엇이 바뀌었는지 알 수 없으니 전부 다시 열거한다.
    let dir = try tempDir()
    try Data().write(to: dir.appendingPathComponent("a.jsonl"))
    let cache = RecentFileCache(ttl: 120)
    _ = cache.files(under: dir, suffix: ".jsonl")
    try Data().write(to: dir.appendingPathComponent("b.jsonl"))
    cache.note(path: dir.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
    #expect(cache.files(under: dir, suffix: ".jsonl").count == 2)
}

@Test func listsAreCachedPerDirectoryAndSuffix() throws {
    let dir = try tempDir()
    try Data().write(to: dir.appendingPathComponent("a.jsonl"))
    try Data().write(to: dir.appendingPathComponent("x.log"))
    let cache = RecentFileCache(ttl: 120)
    #expect(names(cache.files(under: dir, suffix: ".jsonl")) == ["a.jsonl"])
    #expect(names(cache.files(under: dir, suffix: ".log")) == ["x.log"])
}
