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

// MARK: - marker 사전 필터 + 스트리밍

private func appendText(_ text: String, to file: URL) throws {
    let h = try FileHandle(forWritingTo: file)
    try h.seekToEnd()
    try h.write(contentsOf: Data(text.utf8))
    try h.close()
}

private func tmpFile(_ name: String = "log.jsonl") throws -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiglass-rd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, dir.appendingPathComponent(name))
}

@Test func markerFilterReturnsOnlyMatchingLinesAndStillAdvances() throws {
    let (dir, file) = try tmpFile(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("noise-1\nTOKEN-a\nnoise-2\n\nTOKEN-b\n".utf8).write(to: file)
    let reader = IncrementalLineReader()
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-a", "TOKEN-b"])
    // 매칭 안 된 줄도 오프셋은 넘어갔다 — 같은 내용 재호출 → 없음
    #expect(reader.newLines(of: file, containing: "TOKEN") == [])
    try appendText("noise-3\nTOKEN-c\n", to: file)
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-c"])
}

@Test func markerFilterKeepsPartialTailUntilCompleted() throws {
    let (dir, file) = try tmpFile(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("TOKEN-1\nTOKEN-par".utf8).write(to: file)
    let reader = IncrementalLineReader()
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-1"])
    try appendText("tial\n", to: file)
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-partial"])
}

@Test func onlyIncompleteLineLeavesOffsetUntouched() throws {
    let (dir, file) = try tmpFile(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("TOKEN-no-newline-yet".utf8).write(to: file)
    let reader = IncrementalLineReader()
    #expect(reader.newLines(of: file, containing: "TOKEN") == []) // 완성된 줄이 없으니 소비 없음
    try appendText("\n", to: file)
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-no-newline-yet"]) // 이어서 읽힘
}

@Test func markerFilterWorksAcrossChunkBoundariesIncrementally() throws {
    let (dir, file) = try tmpFile(); defer { try? FileManager.default.removeItem(at: dir) }
    // ~9MB: 4MB 청크 경계를 두 번 넘는다. 줄 길이를 제각각으로 해서 경계가 줄 중간에 떨어지게 한다.
    var lines: [String] = []
    var total = 0, n = 0
    while total < 9 * 1024 * 1024 {
        let pad = String(repeating: "z", count: 500 + (n * 7919) % 80_000)
        lines.append(n % 20 == 0 ? "TOKEN-\(n)-\(pad)" : "noise-\(n)-\(pad)")
        total += pad.utf8.count + 12
        n += 1
    }
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    let expected = (0..<lines.count).filter { $0 % 20 == 0 }

    func ids(_ got: [String]) -> [Int] {
        got.map { Int($0.dropFirst("TOKEN-".count).prefix { $0 != "-" })! }
    }
    let reader = IncrementalLineReader()
    #expect(ids(reader.newLines(of: file, containing: "TOKEN")) == expected) // 빠짐·중복·순서 오류 없음
    #expect(reader.newLines(of: file, containing: "TOKEN") == [])

    // 큰 파일에 이어 붙인 새 줄만 증분으로 읽힌다
    try appendText("noise-x\nTOKEN-999999-end\n", to: file)
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-999999-end"])
}

@Test func withoutMarkerBehaviorIsUnchangedForLargeLines() throws {
    let (dir, file) = try tmpFile(); defer { try? FileManager.default.removeItem(at: dir) }
    let huge = String(repeating: "h", count: 5 * 1024 * 1024) // 청크(4MB)보다 큰 한 줄
    try Data("a\n\(huge)\nb\n".utf8).write(to: file)
    let got = IncrementalLineReader().newLines(of: file)
    #expect(got.count == 3)
    #expect(got[0] == "a" && got[2] == "b" && got[1].utf8.count == huge.utf8.count)
}

@Test func truncatedFileIsReadFromTheStartAgain() throws {
    let (dir, file) = try tmpFile(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("TOKEN-old-1\nTOKEN-old-2\nTOKEN-old-3\n".utf8).write(to: file)
    let reader = IncrementalLineReader()
    #expect(reader.newLines(of: file, containing: "TOKEN").count == 3)
    try Data("TOKEN-new\n".utf8).write(to: file) // 교체/순환: 이전 오프셋보다 짧아짐
    #expect(reader.newLines(of: file, containing: "TOKEN") == ["TOKEN-new"])
}
