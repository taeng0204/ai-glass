import Foundation

/// 토큰 이벤트의 추정 비용(USD)을 계산한다.
///
/// 주의: 여기 단가는 **API 환산 추정치, 2026-06 기준**이며 실제 구독 실비가 아니다.
/// 구독제(예: Claude Pro/Max, Codex 플랜)는 정액이므로, 이 값은 "API로 같은 양을
/// 썼다면 얼마였을까"를 가늠하는 참고치일 뿐이다.
public enum CostEstimator {
    /// USD per million tokens (MTok).
    struct Rate {
        let input: Double
        let output: Double
    }

    // API 환산 추정치, 2026-06 기준.
    private static let rates: [(prefix: String, rate: Rate)] = [
        ("claude-fable", Rate(input: 10.0, output: 50.0)),
        ("claude-opus", Rate(input: 5.0, output: 25.0)),
        ("claude-sonnet", Rate(input: 3.0, output: 15.0)),
        ("claude-haiku", Rate(input: 1.0, output: 5.0)),
        ("gpt", Rate(input: 1.25, output: 10.0)),
        ("codex", Rate(input: 1.25, output: 10.0)),
        ("gemini", Rate(input: 1.25, output: 10.0)),
    ]

    private static let fallback = Rate(input: 3.0, output: 15.0)

    private static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        // hasPrefix 우선
        for entry in rates where m.hasPrefix(entry.prefix) {
            return entry.rate
        }
        // 키워드 contains 매칭 (예: "claude-3-opus-20240229" → opus)
        if m.contains("fable") { return Rate(input: 10.0, output: 50.0) }
        if m.contains("opus") { return Rate(input: 5.0, output: 25.0) }
        if m.contains("sonnet") { return Rate(input: 3.0, output: 15.0) }
        if m.contains("haiku") { return Rate(input: 1.0, output: 5.0) }
        if m.contains("gpt") || m.contains("codex") { return Rate(input: 1.25, output: 10.0) }
        if m.contains("gemini") { return Rate(input: 1.25, output: 10.0) }
        return fallback
    }

    /// 단일 이벤트의 추정 비용(USD).
    /// 캐시 단가: cacheRead = 0.1 × input 단가, cacheCreation = 1.25 × input 단가
    /// (Anthropic 기준을 전 모델에 적용 — 추정).
    public static func cost(of event: TokenEvent) -> Double {
        let r = rate(for: event.model)
        let perToken = 1.0 / 1_000_000.0
        let input = Double(event.inputTokens) * r.input * perToken
        let output = Double(event.outputTokens) * r.output * perToken
        let cacheRead = Double(event.cacheReadTokens) * (0.1 * r.input) * perToken
        let cacheCreate = Double(event.cacheCreationTokens) * (1.25 * r.input) * perToken
        return input + output + cacheRead + cacheCreate
    }

    /// 이벤트 배열의 추정 비용 합계(USD).
    public static func cost(of events: [TokenEvent]) -> Double {
        events.reduce(0) { $0 + cost(of: $1) }
    }
}
