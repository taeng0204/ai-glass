import Foundation
import Testing
@testable import AIGlassCore

@Test func opusEventCostHandComputed() {
    // opus: input 5.0, output 25.0, cacheRead 0.1*5=0.5, cacheCreate 1.25*5=6.25 (USD per MTok)
    let e = TokenEvent(service: .claude, timestamp: Date(), model: "claude-opus-4-8",
                       inputTokens: 1_000_000, outputTokens: 1_000_000,
                       cacheReadTokens: 1_000_000, cacheCreationTokens: 1_000_000)
    // 5.0 + 25.0 + 0.5 + 6.25 = 36.75
    #expect(abs(CostEstimator.cost(of: e) - 36.75) < 1e-6)
}

@Test func gptCodexMatches() {
    // gpt-codex: input 1.25, output 10.0
    let e = TokenEvent(service: .codex, timestamp: Date(), model: "gpt-codex",
                       inputTokens: 1_000_000, outputTokens: 1_000_000,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    #expect(abs(CostEstimator.cost(of: e) - 11.25) < 1e-6)
}

@Test func unknownModelFallback() {
    // fallback: input 3.0, output 15.0
    let e = TokenEvent(service: .gemini, timestamp: Date(), model: "totally-unknown-model",
                       inputTokens: 1_000_000, outputTokens: 1_000_000,
                       cacheReadTokens: 0, cacheCreationTokens: 0)
    #expect(abs(CostEstimator.cost(of: e) - 18.0) < 1e-6)
}

@Test func costOfArraySums() {
    let a = TokenEvent(service: .claude, timestamp: Date(), model: "claude-haiku",
                       inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    let b = TokenEvent(service: .gemini, timestamp: Date(), model: "gemini-2.5",
                       inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    // haiku input 1.0 + gemini input 1.25 = 2.25
    #expect(abs(CostEstimator.cost(of: [a, b]) - 2.25) < 1e-6)
}
