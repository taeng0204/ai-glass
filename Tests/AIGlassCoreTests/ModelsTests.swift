import Foundation
import Testing
@testable import AIGlassCore

@Test func tokenEventTotal() {
    let e = TokenEvent(service: .claude, timestamp: Date(), model: "claude-opus-4-8",
                       inputTokens: 100, outputTokens: 50, cacheReadTokens: 1000, cacheCreationTokens: 200)
    #expect(e.totalTokens == 1350)
}

@Test func serviceDisplayNames() {
    #expect(ServiceID.claude.displayName == "Claude")
    #expect(ServiceID.codex.displayName == "Codex")
    #expect(ServiceID.gemini.displayName == "Gemini")
}

@Test func iso8601ParsesFractionalAndPlain() {
    #expect(ISO8601.date("2026-06-10T10:52:36.739Z") != nil)
    #expect(ISO8601.date("2026-06-10T10:52:36Z") != nil)
    #expect(ISO8601.date("not-a-date") == nil)
}
