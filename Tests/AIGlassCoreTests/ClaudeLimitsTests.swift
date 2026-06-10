import Foundation
import Testing
@testable import AIGlassCore

private let usageJSON = """
{"five_hour":{"utilization":38.5,"resets_at":"2026-06-10T15:00:00Z"},"seven_day":{"utilization":21.0,"resets_at":"2026-06-15T00:00:00Z"}}
"""

@Test func parsesUsageResponse() throws {
    let windows = try #require(ClaudeUsageAPI.parse(Data(usageJSON.utf8)))
    #expect(windows.count == 2)
    let session = try #require(windows.first { $0.kind == .session5h })
    #expect(session.usedPercent == 38.5)
    #expect(session.resetsAt == ISO8601.date("2026-06-10T15:00:00Z"))
    #expect(windows.contains { $0.kind == .weekly && $0.usedPercent == 21.0 })
}

@Test func parsesPartialWindowResponse() throws {
    let json = #"{"five_hour":{"utilization":50.0,"resets_at":"2026-06-10T15:00:00Z"}}"#
    let windows = try #require(ClaudeUsageAPI.parse(Data(json.utf8)))
    #expect(windows.count == 1)
    #expect(windows.first?.kind == .session5h)
}

@Test func parseFailsGracefully() {
    #expect(ClaudeUsageAPI.parse(Data("{}".utf8)) == nil)
    #expect(ClaudeUsageAPI.parse(Data("nope".utf8)) == nil)
}

@Test func keychainPayloadParsing() {
    let payload = #"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1780000000000}}"#
    #expect(ClaudeCredentials.parse(Data(payload.utf8))?.accessToken == "tok-123")
    #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
}
