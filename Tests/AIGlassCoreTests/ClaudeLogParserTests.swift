import Foundation
import Testing
@testable import AIGlassCore

private let claudeLine = """
{"parentUuid":"x","cwd":"/tmp","sessionId":"s1","version":"2.0.0","gitBranch":"main","type":"assistant","requestId":"req_1","timestamp":"2026-06-10T10:52:36.739Z","uuid":"u1","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":15207,"cache_creation_input_tokens":100,"cache_read_input_tokens":29789,"output_tokens":962}}}
"""

@Test func parsesUsageLine() throws {
    let (event, key) = try #require(ClaudeLogParser.parse(line: claudeLine))
    #expect(event.service == .claude)
    #expect(event.model == "claude-opus-4-8")
    #expect(event.inputTokens == 15207)
    #expect(event.outputTokens == 962)
    #expect(event.cacheReadTokens == 29789)
    #expect(event.cacheCreationTokens == 100)
    #expect(key == "msg_1:req_1")
    #expect(event.timestamp == ISO8601.date("2026-06-10T10:52:36.739Z"))
}

@Test func skipsLinesWithoutUsage() {
    #expect(ClaudeLogParser.parse(line: #"{"type":"user","timestamp":"2026-06-10T10:00:00Z","message":{"role":"user","content":"hi"}}"#) == nil)
    #expect(ClaudeLogParser.parse(line: "not json") == nil)
    #expect(ClaudeLogParser.parse(line: "") == nil)
    #expect(ClaudeLogParser.parse(line: "   ") == nil)
}

@Test func skipsSyntheticModel() {
    let line = claudeLine.replacingOccurrences(of: "claude-opus-4-8", with: "<synthetic>")
    #expect(ClaudeLogParser.parse(line: line) == nil)
}
