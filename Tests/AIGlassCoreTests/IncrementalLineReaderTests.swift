import Foundation
import Testing
@testable import AIGlassCore

@Test func readsOnlyNewCompleteLines() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("log.jsonl")

    try Data("line1\nline2\n".utf8).write(to: file)
    let reader = IncrementalLineReader()
    #expect(reader.newLines(of: file) == ["line1", "line2"])
    #expect(reader.newLines(of: file) == []) // 같은 내용 재호출 → 없음

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("line3\npartial".utf8)) // 마지막 줄 미완성
    try handle.close()
    #expect(reader.newLines(of: file) == ["line3"]) // 완성된 줄만

    let handle2 = try FileHandle(forWritingTo: file)
    try handle2.seekToEnd()
    try handle2.write(contentsOf: Data("-done\n".utf8))
    try handle2.close()
    #expect(reader.newLines(of: file) == ["partial-done"])
}

@Test func locatorFindsRecentFilesRecursively() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aiglass-loc-\(UUID().uuidString)")
    let sub = dir.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x\n".utf8).write(to: sub.appendingPathComponent("new.jsonl"))
    try Data("x\n".utf8).write(to: sub.appendingPathComponent("skip.txt"))
    let old = sub.appendingPathComponent("old.jsonl")
    try Data("x\n".utf8).write(to: old)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: old.path)

    let found = LogLocator.recentFiles(under: dir, suffix: ".jsonl", modifiedWithinDays: 8)
    #expect(found.map(\.lastPathComponent) == ["new.jsonl"])
}
