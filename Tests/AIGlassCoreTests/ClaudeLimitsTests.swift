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

@Test func parsesExpiresAtMilliseconds() throws {
    let payload = #"{"claudeAiOauth":{"accessToken":"tok-123","expiresAt":1780000000000}}"#
    let creds = try #require(ClaudeCredentials.parse(Data(payload.utf8)))
    #expect(creds.expiresAt == Date(timeIntervalSince1970: 1780000000))
}

@Test func expiresAtNilWhenAbsent() throws {
    let payload = #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#
    let creds = try #require(ClaudeCredentials.parse(Data(payload.utf8)))
    #expect(creds.expiresAt == nil)
}

@MainActor
@Test func tokenProviderCacheHitSkipsReader() {
    var calls = 0
    let now = Date(timeIntervalSince1970: 1_000_000)
    let provider = ClaudeTokenProvider {
        calls += 1
        return ClaudeCredentials(accessToken: "tok", expiresAt: now.addingTimeInterval(3600))
    }
    #expect(provider.token(now: now) == "tok")
    #expect(provider.token(now: now.addingTimeInterval(100)) == "tok")
    #expect(calls == 1) // 캐시 적중 — reader 1회만
}

@MainActor
@Test func tokenProviderRefetchesWhenExpiring() {
    var calls = 0
    let now = Date(timeIntervalSince1970: 1_000_000)
    let provider = ClaudeTokenProvider {
        calls += 1
        return ClaudeCredentials(accessToken: "tok\(calls)", expiresAt: now.addingTimeInterval(30))
    }
    #expect(provider.token(now: now) == "tok1")
    // 만료 임박(now+60s 이내)이므로 재조회
    #expect(provider.token(now: now) == "tok2")
    #expect(calls == 2)
}

@MainActor
@Test func tokenProviderNilExpiryStaysCached() {
    var calls = 0
    let provider = ClaudeTokenProvider {
        calls += 1
        return ClaudeCredentials(accessToken: "tok", expiresAt: nil)
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(provider.token(now: now) == "tok")
    #expect(provider.token(now: now.addingTimeInterval(99999)) == "tok")
    #expect(calls == 1)
}

@MainActor
@Test func tokenProviderInvalidateForcesRefetch() {
    var calls = 0
    let provider = ClaudeTokenProvider {
        calls += 1
        return ClaudeCredentials(accessToken: "tok", expiresAt: nil)
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    _ = provider.token(now: now)
    provider.invalidate()
    _ = provider.token(now: now)
    #expect(calls == 2)
}
